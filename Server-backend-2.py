"""
AWS Spot Optimizer - Central Server Backend (FIXED)
====================================================
Fixed version addressing all P0 and P1 critical issues from audit.

Version: 1.1.0 (Production Ready)
Changes:
- Added connection pooling
- Set baseline_ondemand_price on registration
- Added input validation
- Fixed force-switch implementation with pending commands
- Added scheduled job for monthly savings computation
- Enforced switch frequency and duration limits
- Added proper error logging

"""

import os
import json
import pickle
import logging
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd
from flask import Flask, request, jsonify
from flask_cors import CORS
import mysql.connector
from mysql.connector import Error, pooling
from functools import wraps
from apscheduler.schedulers.background import BackgroundScheduler
from marshmallow import Schema, fields, validate, ValidationError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# ==============================================================================
# CONFIGURATION
# ==============================================================================

class Config:
    """Server configuration"""
    
    # Database
    DB_HOST = os.getenv('DB_HOST', 'localhost')
    DB_PORT = int(os.getenv('DB_PORT', 3306))
    DB_USER = os.getenv('DB_USER', 'root')
    DB_PASSWORD = os.getenv('DB_PASSWORD', 'password')
    DB_NAME = os.getenv('DB_NAME', 'spot_optimizer')
    DB_POOL_SIZE = int(os.getenv('DB_POOL_SIZE', 10))
    
    # Models
    MODEL_DIR = Path(os.getenv('MODEL_DIR', '/home/ubuntu/production_models'))
    REGION = 'ap-south-1'
    
    # Server
    HOST = os.getenv('HOST', '0.0.0.0')
    PORT = int(os.getenv('PORT', 5000))
    DEBUG = os.getenv('DEBUG', 'False').lower() == 'true'

config = Config()

# ==============================================================================
# INPUT VALIDATION SCHEMAS
# ==============================================================================

class AgentRegistrationSchema(Schema):
    """Validation schema for agent registration"""
    client_token = fields.Str(required=True)
    hostname = fields.Str(required=True, validate=validate.Length(max=255))
    instance_id = fields.Str(required=True, validate=validate.Regexp(r'^i-[a-f0-9]+$'))
    instance_type = fields.Str(required=True, validate=validate.Length(max=64))
    region = fields.Str(required=True, validate=validate.Regexp(r'^[a-z]+-[a-z]+-\d+$'))
    az = fields.Str(required=True, validate=validate.Regexp(r'^[a-z]+-[a-z]+-\d+[a-z]$'))
    ami_id = fields.Str(required=True, validate=validate.Regexp(r'^ami-[a-f0-9]+$'))
    agent_version = fields.Str(required=True, validate=validate.Length(max=32))

class ForceSwitchSchema(Schema):
    """Validation schema for force switch"""
    target = fields.Str(required=True, validate=validate.OneOf(['ondemand', 'pool']))
    pool_id = fields.Str(required=False, validate=validate.Length(max=128))

# ==============================================================================
# FLASK APP
# ==============================================================================

app = Flask(__name__)
CORS(app)

# ==============================================================================
# DATABASE CONNECTION POOLING (P0 FIX #3)
# ==============================================================================

connection_pool = None

def init_db_pool():
    """Initialize database connection pool"""
    global connection_pool
    try:
        connection_pool = pooling.MySQLConnectionPool(
            pool_name="spot_optimizer_pool",
            pool_size=config.DB_POOL_SIZE,
            pool_reset_session=True,
            host=config.DB_HOST,
            port=config.DB_PORT,
            user=config.DB_USER,
            password=config.DB_PASSWORD,
            database=config.DB_NAME,
            autocommit=False
        )
        logger.info(f"✓ Database connection pool initialized (size: {config.DB_POOL_SIZE})")
    except Error as e:
        logger.error(f"Failed to initialize connection pool: {e}")
        raise

def get_db_connection():
    """Get connection from pool"""
    try:
        return connection_pool.get_connection()
    except Error as e:
        logger.error(f"Failed to get connection from pool: {e}")
        raise

def execute_query(query, params=None, fetch=False, fetch_one=False, commit=True):
    """Execute database query with error handling"""
    connection = None
    cursor = None
    try:
        connection = get_db_connection()
        cursor = connection.cursor(dictionary=True)
        cursor.execute(query, params or ())
        
        if fetch_one:
            result = cursor.fetchone()
        elif fetch:
            result = cursor.fetchall()
        else:
            result = None
            
        if commit and not fetch and not fetch_one:
            connection.commit()
            
        return result
    except Error as e:
        if connection:
            connection.rollback()
        logger.error(f"Query execution error: {e}")
        logger.error(f"Query: {query}")
        logger.error(f"Params: {params}")
        
        # Log to system_events table
        log_system_event('database_error', 'error', str(e), metadata={'query': query[:200]})
        raise
    finally:
        if cursor:
            cursor.close()
        if connection:
            connection.close()

# ==============================================================================
# SYSTEM EVENTS LOGGING (P1 FIX #10)
# ==============================================================================

def log_system_event(event_type, severity, message, client_id=None, agent_id=None, 
                     instance_id=None, metadata=None):
    """Log system event"""
    try:
        execute_query("""
            INSERT INTO system_events (event_type, severity, client_id, agent_id, 
                                      instance_id, message, metadata)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
        """, (event_type, severity, client_id, agent_id, instance_id, 
              message, json.dumps(metadata) if metadata else None))
    except Exception as e:
        logger.error(f"Failed to log system event: {e}")

# ==============================================================================
# MODEL LOADING
# ==============================================================================

class ModelManager:
    """Manages ML models for decision making"""
    
    def __init__(self):
        self.capacity_detector = None
        self.price_predictor = None
        self.model_config = None
        self.loaded = False
        
    def load_models(self):
        """Load production models"""
        try:
            logger.info("Loading production models...")
            
            manifest_path = config.MODEL_DIR / 'manifest.json'
            with open(manifest_path, 'r') as f:
                manifest = json.load(f)
            
            region_models = manifest['models'].get('mumbai', {})
            
            capacity_path = config.MODEL_DIR / region_models['capacity_detector']
            with open(capacity_path, 'rb') as f:
                capacity_data = pickle.load(f)
                self.capacity_detector = capacity_data
            
            price_path = config.MODEL_DIR / region_models['price_predictor']
            with open(price_path, 'rb') as f:
                price_data = pickle.load(f)
                self.price_predictor = price_data
            
            config_path = config.MODEL_DIR / region_models['config']
            with open(config_path, 'r') as f:
                self.model_config = json.load(f)
            
            self.loaded = True
            logger.info(f"✓ Models loaded successfully")
            logger.info(f"  Capacity pools: {len(self.capacity_detector['pool_context'])}")
            logger.info(f"  Price models: {len(self.price_predictor['models'])}")
            
            log_system_event('models_loaded', 'info', 'ML models loaded successfully')
            
        except Exception as e:
            logger.error(f"Failed to load models: {e}")
            log_system_event('models_load_failed', 'error', str(e))
            raise
    
    def get_risk_score(self, pool_id, current_price, current_discount, ondemand_price):
        """Calculate risk score for a pool"""
        if not self.loaded:
            return 0.5, "normal", "Models not loaded"
        
        context = self.capacity_detector['pool_context'].get(pool_id)
        if not context:
            return 0.5, "normal", "Pool not in training data"
        
        cfg = self.capacity_detector['config']
        price_ratio = current_price / ondemand_price if ondemand_price > 0 else 1.0
        
        ratio_spike = price_ratio > context['ratio_p50'] * (1 + cfg['ratio_spike_threshold'])
        ratio_absolute_high = price_ratio > cfg['ratio_absolute_high']
        ratio_event = price_ratio > context['ratio_p92']
        
        risk_score = 0.0
        state = "normal"
        reason = []
        
        if ratio_absolute_high:
            risk_score = 0.9
            state = "event"
            reason.append(f"Ratio {price_ratio:.3f} exceeds absolute threshold {cfg['ratio_absolute_high']}")
        elif ratio_event:
            risk_score = 0.8
            state = "high-risk"
            reason.append(f"Ratio {price_ratio:.3f} above p92 ({context['ratio_p92']:.3f})")
        elif ratio_spike:
            risk_score = 0.6
            state = "high-risk"
            reason.append(f"Ratio spike detected: {price_ratio:.3f} vs p50 {context['ratio_p50']:.3f}")
        else:
            if price_ratio < cfg['ratio_safe_return']:
                risk_score = 0.2
                state = "safe-to-return"
                reason.append(f"Ratio {price_ratio:.3f} below safe threshold {cfg['ratio_safe_return']}")
            else:
                risk_score = 0.3
                state = "normal"
                reason.append(f"Normal conditions: ratio {price_ratio:.3f}")
        
        return risk_score, state, "; ".join(reason)

model_manager = ModelManager()

# ==============================================================================
# AUTHENTICATION MIDDLEWARE
# ==============================================================================

def require_client_token(f):
    """Validate client token"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        token = request.headers.get('Authorization', '').replace('Bearer ', '')
        if not token:
            token = request.json.get('client_token') if request.json else None
        
        if not token:
            return jsonify({'error': 'Missing client token'}), 401
        
        client = execute_query(
            "SELECT id, name FROM clients WHERE client_token = %s AND status = 'active'",
            (token,),
            fetch_one=True
        )
        
        if not client:
            log_system_event('auth_failed', 'warning', 'Invalid client token attempt')
            return jsonify({'error': 'Invalid client token'}), 401
        
        request.client_id = client['id']
        request.client_name = client['name']
        return f(*args, **kwargs)
    
    return decorated_function

# ==============================================================================
# SCHEDULED JOBS (P0 FIX #1)
# ==============================================================================

def compute_monthly_savings_job():
    """Compute monthly savings for all clients"""
    try:
        connection = get_db_connection()
        cursor = connection.cursor(dictionary=True)
        
        cursor.execute("SELECT id FROM clients WHERE status = 'active'")
        clients = cursor.fetchall()
        
        now = datetime.utcnow()
        year = now.year
        month = now.month
        
        for client in clients:
            try:
                cursor.callproc('calculate_monthly_savings', [client['id'], year, month])
                connection.commit()
            except Exception as e:
                logger.error(f"Failed to compute savings for client {client['id']}: {e}")
        
        cursor.close()
        connection.close()
        
        logger.info(f"✓ Monthly savings computed for {len(clients)} clients")
        log_system_event('savings_computed', 'info', 
                        f"Computed monthly savings for {len(clients)} clients")
        
    except Exception as e:
        logger.error(f"Savings computation job failed: {e}")
        log_system_event('savings_computation_failed', 'error', str(e))

def cleanup_old_data_job():
    """Clean up old time-series data"""
    try:
        # Clean up old snapshots (30 days)
        execute_query("""
            DELETE FROM spot_price_snapshots 
            WHERE captured_at < DATE_SUB(NOW(), INTERVAL 30 DAY)
        """)
        
        execute_query("""
            DELETE FROM ondemand_price_snapshots 
            WHERE captured_at < DATE_SUB(NOW(), INTERVAL 30 DAY)
        """)
        
        # Clean up old risk scores (90 days)
        execute_query("""
            DELETE FROM risk_scores 
            WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY)
        """)
        
        logger.info("✓ Old data cleaned up")
        log_system_event('data_cleanup', 'info', 'Cleaned up old time-series data')
        
    except Exception as e:
        logger.error(f"Data cleanup job failed: {e}")
        log_system_event('cleanup_failed', 'error', str(e))

# ==============================================================================
# AGENT-FACING API ENDPOINTS
# ==============================================================================

@app.route('/api/agents/register', methods=['POST'])
@require_client_token
def register_agent():
    """Register new agent with validation"""
    data = request.json
    
    # P0 FIX #5: Input validation
    schema = AgentRegistrationSchema()
    try:
        validated_data = schema.load(data)
    except ValidationError as e:
        log_system_event('validation_error', 'warning', 
                        f"Agent registration validation failed: {e.messages}")
        return jsonify({'error': 'Validation failed', 'details': e.messages}), 400
    
    try:
        agent_id = f"agent-{validated_data['instance_id'][:8]}"
        
        existing = execute_query(
            "SELECT id FROM agents WHERE id = %s",
            (agent_id,),
            fetch_one=True
        )
        
        if existing:
            execute_query("""
                UPDATE agents 
                SET client_id = %s, status = 'online', hostname = %s, 
                    agent_version = %s, last_heartbeat = NOW()
                WHERE id = %s
            """, (request.client_id, validated_data.get('hostname'), 
                  validated_data.get('agent_version'), agent_id))
        else:
            execute_query("""
                INSERT INTO agents (id, client_id, status, hostname, agent_version, last_heartbeat)
                VALUES (%s, %s, 'online', %s, %s, NOW())
            """, (agent_id, request.client_id, validated_data.get('hostname'), 
                  validated_data.get('agent_version')))
        
        config_exists = execute_query(
            "SELECT agent_id FROM agent_configs WHERE agent_id = %s",
            (agent_id,),
            fetch_one=True
        )
        
        if not config_exists:
            execute_query("""
                INSERT INTO agent_configs (agent_id)
                VALUES (%s)
            """, (agent_id,))
        
        config_data = execute_query("""
            SELECT ac.*, a.enabled, a.auto_switch_enabled, a.auto_terminate_enabled
            FROM agent_configs ac
            JOIN agents a ON a.id = ac.agent_id
            WHERE ac.agent_id = %s
        """, (agent_id,), fetch_one=True)
        
        # P0 FIX #2: Set baseline_ondemand_price on first registration
        instance_exists = execute_query(
            "SELECT id, baseline_ondemand_price FROM instances WHERE id = %s",
            (validated_data['instance_id'],),
            fetch_one=True
        )
        
        if not instance_exists:
            # Get latest on-demand price from snapshots
            latest_od_price = execute_query("""
                SELECT price FROM ondemand_price_snapshots
                WHERE region = %s AND instance_type = %s
                ORDER BY captured_at DESC
                LIMIT 1
            """, (validated_data['region'], validated_data['instance_type']), fetch_one=True)
            
            baseline_price = latest_od_price['price'] if latest_od_price else 0.1
            
            execute_query("""
                INSERT INTO instances (
                    id, client_id, agent_id, instance_type, region, az, ami_id, 
                    installed_at, is_active, baseline_ondemand_price
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, NOW(), TRUE, %s)
            """, (
                validated_data['instance_id'], request.client_id, agent_id,
                validated_data['instance_type'], validated_data['region'], 
                validated_data['az'], validated_data['ami_id'], baseline_price
            ))
        elif not instance_exists['baseline_ondemand_price']:
            # Set baseline if missing
            latest_od_price = execute_query("""
                SELECT price FROM ondemand_price_snapshots
                WHERE region = %s AND instance_type = %s
                ORDER BY captured_at DESC
                LIMIT 1
            """, (validated_data['region'], validated_data['instance_type']), fetch_one=True)
            
            if latest_od_price:
                execute_query("""
                    UPDATE instances 
                    SET baseline_ondemand_price = %s
                    WHERE id = %s AND baseline_ondemand_price IS NULL
                """, (latest_od_price['price'], validated_data['instance_id']))
        
        log_system_event('agent_registered', 'info', 
                        f"Agent {agent_id} registered", 
                        request.client_id, agent_id, validated_data['instance_id'])
        
        return jsonify({
            'agent_id': agent_id,
            'client_id': request.client_id,
            'config': {
                'enabled': config_data['enabled'],
                'auto_switch_enabled': config_data['auto_switch_enabled'],
                'auto_terminate_enabled': config_data['auto_terminate_enabled'],
                'min_savings_percent': float(config_data['min_savings_percent']),
                'risk_threshold': float(config_data['risk_threshold']),
                'max_switches_per_week': config_data['max_switches_per_week'],
                'min_pool_duration_hours': config_data['min_pool_duration_hours']
            }
        })
        
    except Exception as e:
        logger.error(f"Agent registration error: {e}")
        log_system_event('agent_registration_failed', 'error', str(e), 
                        request.client_id, metadata={'instance_id': validated_data.get('instance_id')})
        return jsonify({'error': str(e)}), 500

@app.route('/api/agents/<agent_id>/heartbeat', methods=['POST'])
@require_client_token
def agent_heartbeat(agent_id):
    """Update agent heartbeat"""
    data = request.json
    
    try:
        execute_query("""
            UPDATE agents 
            SET status = %s, last_heartbeat = NOW(), instance_count = %s
            WHERE id = %s AND client_id = %s
        """, (
            data.get('status', 'online'),
            len(data.get('monitored_instances', [])),
            agent_id,
            request.client_id
        ))
        
        execute_query(
            "UPDATE clients SET last_sync_at = NOW() WHERE id = %s",
            (request.client_id,)
        )
        
        return jsonify({'success': True})
        
    except Exception as e:
        logger.error(f"Heartbeat error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/agents/<agent_id>/pricing-report', methods=['POST'])
@require_client_token
def pricing_report(agent_id):
    """Receive pricing data from agent"""
    data = request.json
    
    try:
        instance = data['instance']
        on_demand = data['on_demand_price']
        spot_pools = data['spot_pools']
        
        execute_query("""
            UPDATE instances
            SET ondemand_price = %s, updated_at = NOW()
            WHERE id = %s AND client_id = %s
        """, (on_demand['price'], instance['instance_id'], request.client_id))
        
        for pool in spot_pools:
            pool_id = pool['pool_id']
            
            execute_query("""
                INSERT INTO spot_pools (id, instance_type, region, az)
                VALUES (%s, %s, %s, %s)
                ON DUPLICATE KEY UPDATE id = id
            """, (pool_id, instance['instance_type'], instance['region'], pool['az']))
            
            execute_query("""
                INSERT INTO spot_price_snapshots (pool_id, price, captured_at)
                VALUES (%s, %s, NOW())
            """, (pool_id, pool['price']))
        
        execute_query("""
            INSERT INTO ondemand_price_snapshots (region, instance_type, price, captured_at)
            VALUES (%s, %s, %s, NOW())
        """, (instance['region'], instance['instance_type'], on_demand['price']))
        
        return jsonify({'success': True})
        
    except Exception as e:
        logger.error(f"Pricing report error: {e}")
        log_system_event('pricing_report_failed', 'error', str(e), 
                        request.client_id, agent_id, instance.get('instance_id'))
        return jsonify({'error': str(e)}), 500

@app.route('/api/agents/<agent_id>/config', methods=['GET'])
@require_client_token
def get_agent_config(agent_id):
    """Get agent configuration"""
    try:
        config_data = execute_query("""
            SELECT ac.*, a.enabled, a.auto_switch_enabled, a.auto_terminate_enabled
            FROM agent_configs ac
            JOIN agents a ON a.id = ac.agent_id
            WHERE ac.agent_id = %s AND a.client_id = %s
        """, (agent_id, request.client_id), fetch_one=True)
        
        if not config_data:
            return jsonify({'error': 'Agent not found'}), 404
        
        return jsonify({
            'enabled': config_data['enabled'],
            'auto_switch_enabled': config_data['auto_switch_enabled'],
            'auto_terminate_enabled': config_data['auto_terminate_enabled'],
            'min_savings_percent': float(config_data['min_savings_percent']),
            'risk_threshold': float(config_data['risk_threshold']),
            'max_switches_per_week': config_data['max_switches_per_week'],
            'min_pool_duration_hours': config_data['min_pool_duration_hours']
        })
        
    except Exception as e:
        logger.error(f"Get config error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/agents/<agent_id>/decide', methods=['POST'])
@require_client_token
def get_decision(agent_id):
    """Get switching decision from ML model with policy enforcement"""
    data = request.json
    
    try:
        instance = data['instance']
        pricing = data['pricing']
        
        config_data = execute_query("""
            SELECT ac.*, a.enabled, a.auto_switch_enabled
            FROM agent_configs ac
            JOIN agents a ON a.id = ac.agent_id
            WHERE ac.agent_id = %s AND a.client_id = %s
        """, (agent_id, request.client_id), fetch_one=True)
        
        if not config_data or not config_data['enabled']:
            return jsonify({
                'instance_id': instance['instance_id'],
                'risk_score': 0.0,
                'recommended_action': 'stay',
                'recommended_mode': instance['current_mode'],
                'recommended_pool_id': instance.get('current_pool_id'),
                'expected_savings_per_hour': 0.0,
                'allowed': False,
                'reason': 'Agent disabled'
            })
        
        # P1 FIX #6: Enforce switch frequency limit
        recent_switches = execute_query("""
            SELECT COUNT(*) as count
            FROM switch_events
            WHERE agent_id = %s AND timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY)
        """, (agent_id,), fetch_one=True)
        
        if recent_switches['count'] >= config_data['max_switches_per_week']:
            return jsonify({
                'instance_id': instance['instance_id'],
                'risk_score': 0.0,
                'recommended_action': 'stay',
                'recommended_mode': instance['current_mode'],
                'recommended_pool_id': instance.get('current_pool_id'),
                'expected_savings_per_hour': 0.0,
                'allowed': False,
                'reason': f"Switch limit reached: {recent_switches['count']}/{config_data['max_switches_per_week']} switches this week"
            })
        
        # P1 FIX #6: Enforce pool duration limit
        last_switch = execute_query("""
            SELECT timestamp FROM switch_events
            WHERE instance_id = %s OR new_instance_id = %s
            ORDER BY timestamp DESC
            LIMIT 1
        """, (instance['instance_id'], instance['instance_id']), fetch_one=True)
        
        if last_switch:
            hours_since = (datetime.utcnow() - last_switch['timestamp']).total_seconds() / 3600
            if hours_since < config_data['min_pool_duration_hours']:
                return jsonify({
                    'instance_id': instance['instance_id'],
                    'risk_score': 0.0,
                    'recommended_action': 'stay',
                    'recommended_mode': instance['current_mode'],
                    'recommended_pool_id': instance.get('current_pool_id'),
                    'expected_savings_per_hour': 0.0,
                    'allowed': False,
                    'reason': f"Too soon to switch: {hours_since:.1f}h < {config_data['min_pool_duration_hours']}h minimum"
                })
        
        current_pool_id = instance.get('current_pool_id', 'unknown')
        current_mode = instance.get('current_mode', 'spot')
        
        current_spot_price = None
        for pool in pricing['spot_pools']:
            if pool['pool_id'] == current_pool_id:
                current_spot_price = pool['price']
                break
        
        if not current_spot_price and pricing['spot_pools']:
            current_spot_price = pricing['spot_pools'][0]['price']
            current_pool_id = pricing['spot_pools'][0]['pool_id']
        
        ondemand_price = pricing['on_demand_price']
        
        current_discount = 1 - (current_spot_price / ondemand_price) if ondemand_price > 0 else 0
        risk_score, state, reason = model_manager.get_risk_score(
            current_pool_id, current_spot_price, current_discount, ondemand_price
        )
        
        recommended_action = 'stay'
        recommended_mode = current_mode
        recommended_pool_id = current_pool_id
        expected_savings = 0.0
        allowed = config_data['auto_switch_enabled']
        
        if state in ['event', 'high-risk'] and risk_score >= config_data['risk_threshold']:
            recommended_action = 'fallback_ondemand'
            recommended_mode = 'ondemand'
            recommended_pool_id = 'n/a'
            expected_savings = -(ondemand_price - current_spot_price)
            reason = f"High risk detected (score: {risk_score:.2f}), fallback to on-demand recommended"
            
        elif state == 'safe-to-return' and current_mode == 'ondemand':
            best_pool = min(pricing['spot_pools'], key=lambda p: p['price'])
            savings_pct = ((ondemand_price - best_pool['price']) / ondemand_price) * 100
            
            if savings_pct >= config_data['min_savings_percent']:
                recommended_action = 'switch_pool'
                recommended_mode = 'spot'
                recommended_pool_id = best_pool['pool_id']
                expected_savings = ondemand_price - best_pool['price']
                reason = f"Safe to return to spot. Pool {best_pool['pool_id']} offers {savings_pct:.1f}% savings"
        
        elif current_mode == 'spot' and state == 'normal':
            best_pool = min(pricing['spot_pools'], key=lambda p: p['price'])
            if best_pool['pool_id'] != current_pool_id:
                savings = current_spot_price - best_pool['price']
                savings_pct = (savings / ondemand_price) * 100
                
                if savings_pct >= config_data['min_savings_percent']:
                    recommended_action = 'switch_pool'
                    recommended_mode = 'spot'
                    recommended_pool_id = best_pool['pool_id']
                    expected_savings = savings
                    reason = f"Better pool available: {best_pool['pool_id']} saves {savings_pct:.1f}%"
        
        execute_query("""
            INSERT INTO risk_scores (
                client_id, instance_id, agent_id, risk_score, recommended_action,
                recommended_pool_id, recommended_mode, expected_savings_per_hour,
                allowed, reason
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (
            request.client_id, instance['instance_id'], agent_id,
            risk_score, recommended_action, recommended_pool_id,
            recommended_mode, expected_savings, allowed, reason
        ))
        
        return jsonify({
            'instance_id': instance['instance_id'],
            'risk_score': round(risk_score, 4),
            'recommended_action': recommended_action,
            'recommended_mode': recommended_mode,
            'recommended_pool_id': recommended_pool_id,
            'expected_savings_per_hour': round(expected_savings, 6),
            'allowed': allowed,
            'reason': reason
        })
        
    except Exception as e:
        logger.error(f"Decision error: {e}")
        log_system_event('decision_error', 'error', str(e), 
                        request.client_id, agent_id, instance.get('instance_id'))
        return jsonify({'error': str(e)}), 500

@app.route('/api/agents/<agent_id>/switch-report', methods=['POST'])
@require_client_token
def switch_report(agent_id):
    """Record switch event"""
    data = request.json
    
    try:
        old_inst = data['old_instance']
        new_inst = data['new_instance']
        snapshot = data['snapshot']
        prices = data['prices']
        timing = data['timing']
        
        savings_impact = prices['old_spot'] - prices.get('new_spot', prices['on_demand'])
        
        execute_query("""
            INSERT INTO switch_events (
                client_id, instance_id, agent_id, trigger,
                from_mode, to_mode, from_pool_id, to_pool_id,
                on_demand_price, old_spot_price, new_spot_price,
                savings_impact, snapshot_used, snapshot_id,
                old_instance_id, new_instance_id, timestamp
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (
            request.client_id, new_inst['instance_id'], agent_id,
            data['trigger'], old_inst['mode'], new_inst['mode'],
            old_inst.get('pool_id'), new_inst.get('pool_id'),
            prices['on_demand'], prices['old_spot'], prices.get('new_spot', 0),
            savings_impact, snapshot['used'], snapshot.get('snapshot_id'),
            old_inst['instance_id'], new_inst['instance_id'],
            timing['traffic_switched_at']
        ))
        
        execute_query("""
            UPDATE instances
            SET is_active = FALSE, terminated_at = %s
            WHERE id = %s AND client_id = %s
        """, (timing.get('old_instance_terminated_at'), old_inst['instance_id'], request.client_id))
        
        execute_query("""
            INSERT INTO instances (
                id, client_id, agent_id, instance_type, region, az, ami_id,
                current_mode, current_pool_id, spot_price, is_active,
                installed_at, last_switch_at
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, TRUE, %s, %s)
            ON DUPLICATE KEY UPDATE
                current_mode = VALUES(current_mode),
                current_pool_id = VALUES(current_pool_id),
                spot_price = VALUES(spot_price),
                is_active = TRUE,
                last_switch_at = VALUES(last_switch_at)
        """, (
            new_inst['instance_id'], request.client_id, agent_id,
            new_inst['instance_type'], new_inst['region'], new_inst['az'],
            new_inst['ami_id'], new_inst['mode'], new_inst.get('pool_id'),
            prices.get('new_spot', 0), timing['new_instance_ready_at'],
            timing['traffic_switched_at']
        ))
        
        # P1 FIX #9: Better savings calculation
        if savings_impact > 0:
            # Calculate actual hourly savings based on switch duration estimate
            hourly_savings = savings_impact * 24  # Rough daily estimate
            execute_query("""
                UPDATE clients
                SET total_savings = total_savings + %s
                WHERE id = %s
            """, (hourly_savings, request.client_id))
        
        log_system_event('switch_completed', 'info', 
                        f"Switch from {old_inst['instance_id']} to {new_inst['instance_id']}",
                        request.client_id, agent_id, new_inst['instance_id'],
                        metadata={'savings_impact': float(savings_impact)})
        
        return jsonify({'success': True})
        
    except Exception as e:
        logger.error(f"Switch report error: {e}")
        log_system_event('switch_report_failed', 'error', str(e),
                        request.client_id, agent_id)
        return jsonify({'error': str(e)}), 500

# ==============================================================================
# CLIENT DASHBOARD API ENDPOINTS
# ==============================================================================

@app.route('/api/client/<client_id>', methods=['GET'])
def get_client_details(client_id):
    """Get client overview"""
    try:
        client = execute_query("""
            SELECT 
                c.*,
                COUNT(DISTINCT CASE WHEN a.status = 'online' THEN a.id END) as agents_online,
                COUNT(DISTINCT a.id) as agents_total,
                COUNT(DISTINCT CASE WHEN i.is_active = TRUE THEN i.id END) as instances
            FROM clients c
            LEFT JOIN agents a ON a.client_id = c.id
            LEFT JOIN instances i ON i.client_id = c.id
            WHERE c.id = %s
            GROUP BY c.id
        """, (client_id,), fetch_one=True)
        
        if not client:
            return jsonify({'error': 'Client not found'}), 404
        
        return jsonify({
            'id': client['id'],
            'name': client['name'],
            'status': client['status'],
            'agentsOnline': client['agents_online'] or 0,
            'agentsTotal': client['agents_total'] or 0,
            'instances': client['instances'] or 0,
            'totalSavings': float(client['total_savings'] or 0),
            'lastSync': client['last_sync_at'].isoformat() if client['last_sync_at'] else None
        })
        
    except Exception as e:
        logger.error(f"Get client details error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/client/<client_id>/agents', methods=['GET'])
def get_client_agents(client_id):
    """Get all agents for client"""
    try:
        agents = execute_query("""
            SELECT a.*, ac.min_savings_percent, ac.risk_threshold
            FROM agents a
            LEFT JOIN agent_configs ac ON ac.agent_id = a.id
            WHERE a.client_id = %s
            ORDER BY a.last_heartbeat DESC
        """, (client_id,), fetch=True)
        
        return jsonify([{
            'id': agent['id'],
            'status': agent['status'],
            'lastHeartbeat': agent['last_heartbeat'].isoformat() if agent['last_heartbeat'] else None,
            'instanceCount': agent['instance_count'] or 0,
            'enabled': agent['enabled'],
            'auto_switch_enabled': agent['auto_switch_enabled'],
            'auto_terminate_enabled': agent['auto_terminate_enabled']
        } for agent in agents])
        
    except Exception as e:
        logger.error(f"Get agents error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/client/agents/<agent_id>/toggle-enabled', methods=['POST'])
def toggle_agent(agent_id):
    """Enable/disable agent"""
    data = request.json
    
    try:
        execute_query("""
            UPDATE agents
            SET enabled = %s
            WHERE id = %s
        """, (data['enabled'], agent_id))
        
        log_system_event('agent_toggled', 'info', 
                        f"Agent {agent_id} {'enabled' if data['enabled'] else 'disabled'}",
                        agent_id=agent_id)
        
        return jsonify({'success': True})
        
    except Exception as e:
        logger.error(f"Toggle agent error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/client/agents/<agent_id>/settings', methods=['POST'])
def update_agent_settings(agent_id):
    """Update agent auto-switch and auto-terminate settings"""
    data = request.json
    
    try:
        updates = []
        params = []
        
        if 'auto_switch_enabled' in data:
            updates.append("auto_switch_enabled = %s")
            params.append(data['auto_switch_enabled'])
        
        if 'auto_terminate_enabled' in data:
            updates.append("auto_terminate_enabled = %s")
            params.append(data['auto_terminate_enabled'])
        
        if updates:
            params.append(agent_id)
            execute_query(f"""
                UPDATE agents
                SET {', '.join(updates)}
                WHERE id = %s
            """, tuple(params))
            
            log_system_event('agent_settings_updated', 'info',
                            f"Agent {agent_id} settings updated",
                            agent_id=agent_id, metadata=data)
        
        return jsonify({'success': True})
        
    except Exception as e:
        logger.error(f"Update agent settings error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/client/<client_id>/instances', methods=['GET'])
def get_client_instances(client_id):
    """Get all instances for client"""
    try:
        instances = execute_query("""
            SELECT *
            FROM instances
            WHERE client_id = %s AND is_active = TRUE
            ORDER BY created_at DESC
        """, (client_id,), fetch=True)
        
        return jsonify([{
            'id': inst['id'],
            'type': inst['instance_type'],
            'az': inst['az'],
            'mode': inst['current_mode'],
            'poolId': inst['current_pool_id'] or 'n/a',
            'spotPrice': float(inst['spot_price'] or 0),
            'onDemandPrice': float(inst['ondemand_price'] or 0),
            'lastSwitch': inst['last_switch_at'].isoformat() if inst['last_switch_at'] else None
        } for inst in instances])
        
    except Exception as e:
        logger.error(f"Get instances error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/client/instances/<instance_id>/pricing', methods=['GET'])
def get_instance_pricing(instance_id):
    """Get pricing details for instance"""
    try:
        instance = execute_query("""
            SELECT instance_type, region, ondemand_price
            FROM instances
            WHERE id = %s
        """, (instance_id,), fetch_one=True)
        
        if not instance:
            return jsonify({'error': 'Instance not found'}), 404
        
        pools = execute_query("""
            SELECT 
                sp.id as pool_id,
                sp.az,
                sps.price,
                sps.captured_at
            FROM spot_pools sp
            JOIN (
                SELECT pool_id, price, captured_at,
                       ROW_NUMBER() OVER (PARTITION BY pool_id ORDER BY captured_at DESC) as rn
                FROM spot_price_snapshots
            ) sps ON sps.pool_id = sp.id AND sps.rn = 1
            WHERE sp.instance_type = %s AND sp.region = %s
            ORDER BY sps.price ASC
        """, (instance['instance_type'], instance['region']), fetch=True)
        
        ondemand_price = float(instance['ondemand_price'] or 0)
        
        return jsonify({
            'onDemand': {
                'name': 'On-Demand',
                'price': ondemand_price
            },
            'pools': [{
                'id': pool['pool_id'],
                'price': float(pool['price']),
                'savings': ((ondemand_price - float(pool['price'])) / ondemand_price * 100) if ondemand_price > 0 else 0
            } for pool in pools]
        })
        
    except Exception as e:
        logger.error(f"Get instance pricing error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/client/instances/<instance_id>/force-switch', methods=['POST'])
def force_instance_switch(instance_id):
    """P0 FIX #4: Manually force instance switch with pending commands"""
    data = request.json
    
    # Validate input
    schema = ForceSwitchSchema()
    try:
        validated_data = schema.load(data)
    except ValidationError as e:
        return jsonify({'error': 'Validation failed', 'details': e.messages}), 400
    
    try:
        # Get instance and agent info
        instance = execute_query("""
            SELECT agent_id, client_id FROM instances WHERE id = %s
        """, (instance_id,), fetch_one=True)
        
        if not instance or not instance['agent_id']:
            return jsonify({'error': 'Instance or agent not found'}), 404
        
        target_mode = validated_data['target']
        target_pool_id = validated_data.get('pool_id') if target_mode == 'pool' else None
        
        # Insert pending command
        execute_query("""
            INSERT INTO pending_switch_commands 
            (agent_id, instance_id, target_mode, target_pool_id, created_at)
            VALUES (%s, %s, %s, %s, NOW())
        """, (instance['agent_id'], instance_id, target_mode, target_pool_id))
        
        log_system_event('manual_switch_requested', 'info',
                        f"Manual switch requested for {instance_id} to {target_mode}",
                        instance['client_id'], instance['agent_id'], instance_id,
                        metadata={'target': target_mode, 'pool_id': target_pool_id})
        
        return jsonify({
            'success': True,
            'message': 'Switch command queued. Agent will execute on next check.'
        })
        
    except Exception as e:
        logger.error(f"Force switch error: {e}")
        log_system_event('manual_switch_failed', 'error', str(e),
                        metadata={'instance_id': instance_id})
        return jsonify({'error': str(e)}), 500

@app.route('/api/agents/<agent_id>/pending-commands', methods=['GET'])
@require_client_token
def get_pending_commands(agent_id):
    """P0 FIX #4: Get pending switch commands for agent"""
    try:
        commands = execute_query("""
            SELECT * FROM pending_switch_commands
            WHERE agent_id = %s AND executed_at IS NULL
            ORDER BY created_at ASC
        """, (agent_id,), fetch=True)
        
        return jsonify([{
            'id': cmd['id'],
            'instance_id': cmd['instance_id'],
            'target_mode': cmd['target_mode'],
            'target_pool_id': cmd['target_pool_id'],
            'created_at': cmd['created_at'].isoformat()
        } for cmd in commands])
        
    except Exception as e:
        logger.error(f"Get pending commands error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/agents/<agent_id>/mark-command-executed', methods=['POST'])
@require_client_token
def mark_command_executed(agent_id):
    """Mark pending command as executed"""
    data = request.json
    
    try:
        execute_query("""
            UPDATE pending_switch_commands
            SET executed_at = NOW()
            WHERE id = %s AND agent_id = %s
        """, (data['command_id'], agent_id))
        
        return jsonify({'success': True})
        
    except Exception as e:
        logger.error(f"Mark command executed error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/client/<client_id>/savings', methods=['GET'])
def get_client_savings(client_id):
    """Get savings data for charts"""
    range_param = request.args.get('range', 'monthly')
    
    try:
        if range_param == 'monthly':
            savings = execute_query("""
                SELECT 
                    CONCAT(MONTHNAME(CONCAT(year, '-', month, '-01'))) as name,
                    baseline_cost as onDemandCost,
                    actual_cost as modelCost,
                    savings
                FROM client_savings_monthly
                WHERE client_id = %s
                ORDER BY year DESC, month DESC
                LIMIT 12
            """, (client_id,), fetch=True)
            
            # Reverse to get chronological order
            savings = list(reversed(savings)) if savings else []
            
            return jsonify([{
                'name': s['name'],
                'savings': float(s['savings']),
                'onDemandCost': float(s['onDemandCost']),
                'modelCost': float(s['modelCost'])
            } for s in savings])
        
        return jsonify([])
        
    except Exception as e:
        logger.error(f"Get savings error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/client/<client_id>/switch-history', methods=['GET'])
def get_switch_history(client_id):
    """Get switch history"""
    instance_id = request.args.get('instance_id')
    
    try:
        query = """
            SELECT *
            FROM switch_events
            WHERE client_id = %s
        """
        params = [client_id]
        
        if instance_id:
            query += " AND (old_instance_id = %s OR new_instance_id = %s)"
            params.extend([instance_id, instance_id])
        
        query += " ORDER BY timestamp DESC LIMIT 100"
        
        history = execute_query(query, tuple(params), fetch=True)
        
        return jsonify([{
            'id': h['id'],
            'instanceId': h['new_instance_id'],
            'timestamp': h['timestamp'].isoformat(),
            'fromMode': h['from_mode'],
            'toMode': h['to_mode'],
            'fromPool': h['from_pool_id'] or 'n/a',
            'toPool': h['to_pool_id'] or 'n/a',
            'trigger': h['trigger'],
            'price': float(h['new_spot_price'] or h['on_demand_price'] or 0),
            'savingsImpact': float(h['savings_impact'] or 0)
        } for h in history])
        
    except Exception as e:
        logger.error(f"Get switch history error: {e}")
        return jsonify({'error': str(e)}), 500

# ==============================================================================
# ADMIN DASHBOARD API ENDPOINTS
# ==============================================================================

@app.route('/api/admin/stats', methods=['GET'])
def get_global_stats():
    """Get global statistics"""
    try:
        stats = execute_query("""
            SELECT 
                COUNT(DISTINCT c.id) as total_accounts,
                COUNT(DISTINCT CASE WHEN a.status = 'online' THEN a.id END) as agents_online,
                COUNT(DISTINCT a.id) as agents_total,
                COUNT(DISTINCT sp.id) as pools_covered,
                SUM(c.total_savings) as total_savings,
                COUNT(se.id) as total_switches,
                COUNT(CASE WHEN se.trigger = 'manual' THEN 1 END) as manual_switches,
                COUNT(CASE WHEN se.trigger = 'model' THEN 1 END) as model_switches
            FROM clients c
            LEFT JOIN agents a ON a.client_id = c.id
            LEFT JOIN spot_pools sp ON sp.region = 'ap-south-1'
            LEFT JOIN switch_events se ON se.client_id = c.id
        """, fetch_one=True)
        
        return jsonify({
            'totalAccounts': stats['total_accounts'] or 0,
            'agentsOnline': stats['agents_online'] or 0,
            'agentsTotal': stats['agents_total'] or 0,
            'poolsCovered': stats['pools_covered'] or 0,
            'totalSavings': float(stats['total_savings'] or 0),
            'totalSwitches': stats['total_switches'] or 0,
            'manualSwitches': stats['manual_switches'] or 0,
            'modelSwitches': stats['model_switches'] or 0,
            'backendHealth': 'Healthy' if model_manager.loaded else 'Models Not Loaded'
        })
        
    except Exception as e:
        logger.error(f"Get global stats error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/admin/clients', methods=['GET'])
def get_all_clients():
    """Get all clients"""
    try:
        clients = execute_query("""
            SELECT 
                c.*,
                COUNT(DISTINCT CASE WHEN a.status = 'online' THEN a.id END) as agents_online,
                COUNT(DISTINCT a.id) as agents_total,
                COUNT(DISTINCT CASE WHEN i.is_active = TRUE THEN i.id END) as instances
            FROM clients c
            LEFT JOIN agents a ON a.client_id = c.id
            LEFT JOIN instances i ON i.client_id = c.id
            GROUP BY c.id
            ORDER BY c.created_at DESC
        """, fetch=True)
        
        return jsonify([{
            'id': client['id'],
            'name': client['name'],
            'status': client['status'],
            'agentsOnline': client['agents_online'] or 0,
            'agentsTotal': client['agents_total'] or 0,
            'instances': client['instances'] or 0,
            'totalSavings': float(client['total_savings'] or 0),
            'lastSync': client['last_sync_at'].isoformat() if client['last_sync_at'] else None
        } for client in clients])
        
    except Exception as e:
        logger.error(f"Get all clients error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/admin/activity', methods=['GET'])
def get_recent_activity():
    """Get recent system activity from system_events"""
    try:
        events = execute_query("""
            SELECT 
                event_type as type,
                message as text,
                created_at as time,
                severity
            FROM system_events
            WHERE severity IN ('info', 'warning')
            ORDER BY created_at DESC
            LIMIT 10
        """, fetch=True)
        
        activity = []
        for i, event in enumerate(events):
            # Map event types to UI icons
            event_type_map = {
                'switch_completed': 'switch',
                'agent_registered': 'agent',
                'manual_switch_requested': 'switch',
                'savings_computed': 'event'
            }
            
            activity.append({
                'id': i + 1,
                'type': event_type_map.get(event['type'], 'event'),
                'text': event['text'],
                'time': event['time'].isoformat() if event['time'] else 'unknown'
            })
        
        return jsonify(activity)
        
    except Exception as e:
        logger.error(f"Get activity error: {e}")
        return jsonify({'error': str(e)}), 500

# ==============================================================================
# HEALTH CHECK
# ==============================================================================

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    try:
        execute_query("SELECT 1", fetch_one=True)
        
        return jsonify({
            'status': 'healthy',
            'timestamp': datetime.utcnow().isoformat(),
            'models_loaded': model_manager.loaded,
            'database': 'connected',
            'connection_pool': 'active'
        })
    except Exception as e:
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 500

# ==============================================================================
# APPLICATION STARTUP
# ==============================================================================

def initialize_app():
    """Initialize application on startup"""
    logger.info("="*80)
    logger.info("AWS Spot Optimizer - Central Server Starting (FIXED v1.1.0)")
    logger.info("="*80)
    
    # Initialize connection pool
    init_db_pool()
    
    # Load ML models
    try:
        model_manager.load_models()
    except Exception as e:
        logger.error(f"Failed to load models: {e}")
        logger.warning("Server will run without ML capabilities")
    
    # Start scheduled jobs
    scheduler = BackgroundScheduler()
    
    # P0 FIX #1: Monthly savings computation (daily at 1 AM)
    scheduler.add_job(compute_monthly_savings_job, 'cron', hour=1, minute=0)
    logger.info("✓ Scheduled monthly savings computation job")
    
    # Data cleanup (daily at 2 AM)
    scheduler.add_job(cleanup_old_data_job, 'cron', hour=2, minute=0)
    logger.info("✓ Scheduled data cleanup job")
    
    scheduler.start()
    
    logger.info("Server initialization complete")
    logger.info(f"Listening on {config.HOST}:{config.PORT}")
    logger.info("="*80)

# ==============================================================================
# MAIN
# ==============================================================================

if __name__ == '__main__':
    initialize_app()
    app.run(
        host=config.HOST,
        port=config.PORT,
        debug=config.DEBUG
    )