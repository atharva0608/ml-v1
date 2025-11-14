-- ============================================================================
-- AWS SPOT OPTIMIZER - DATABASE SCHEMA v1.3.0 (PRODUCTION READY)
-- ============================================================================
-- Compatible with MySQL 8.0+
-- Re-runnable: Can be executed multiple times without errors
-- Fixed: All syntax issues, reserved keywords, and delimiter handling
-- Enhanced: Added missing indexes, constraints, and optimizations
-- ============================================================================

-- Create database if not exists
CREATE DATABASE IF NOT EXISTS spot_optimizer
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE spot_optimizer;

-- ============================================================================
-- CLEANUP: DROP EXISTING OBJECTS (RE-RUN SAFE)
-- ============================================================================

-- Drop triggers
DROP TRIGGER IF EXISTS trg_switch_event_update_savings;
DROP TRIGGER IF EXISTS trg_agent_status_change;
DROP TRIGGER IF EXISTS trg_instance_validate_baseline;

-- Drop events
DROP EVENT IF EXISTS evt_daily_cleanup;
DROP EVENT IF EXISTS evt_monthly_savings_computation;
DROP EVENT IF EXISTS evt_quarterly_archive;

-- Drop procedures
DROP PROCEDURE IF EXISTS calculate_monthly_savings;
DROP PROCEDURE IF EXISTS cleanup_old_data;
DROP PROCEDURE IF EXISTS get_agent_statistics;
DROP PROCEDURE IF EXISTS get_pending_commands_for_agent;
DROP PROCEDURE IF EXISTS check_switch_frequency_limit;
DROP PROCEDURE IF EXISTS archive_switch_events;

-- Drop functions
DROP FUNCTION IF EXISTS calculate_savings_percent;
DROP FUNCTION IF EXISTS get_agent_uptime_hours;

-- ============================================================================
-- CORE TABLES
-- ============================================================================

-- Clients table: Represents customer accounts
CREATE TABLE IF NOT EXISTS clients (
  id                VARCHAR(64) PRIMARY KEY,
  name              VARCHAR(255) NOT NULL,
  status            VARCHAR(32) NOT NULL DEFAULT 'active',
  client_token      VARCHAR(255) NOT NULL UNIQUE,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_sync_at      TIMESTAMP NULL DEFAULT NULL,
  total_savings     DECIMAL(18,4) NOT NULL DEFAULT 0.0000,
  
  INDEX idx_status (status),
  INDEX idx_token (client_token),
  INDEX idx_last_sync (last_sync_at),
  INDEX idx_created (created_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Customer accounts using the spot optimizer system';

-- Agents table: Client-side monitoring agents
CREATE TABLE IF NOT EXISTS agents (
  id                      VARCHAR(64) PRIMARY KEY,
  client_id               VARCHAR(64) NOT NULL,
  status                  VARCHAR(32) NOT NULL DEFAULT 'offline',
  enabled                 BOOLEAN NOT NULL DEFAULT TRUE,
  auto_switch_enabled     BOOLEAN NOT NULL DEFAULT TRUE,
  auto_terminate_enabled  BOOLEAN NOT NULL DEFAULT TRUE,
  last_heartbeat          TIMESTAMP NULL DEFAULT NULL,
  instance_count          INT NOT NULL DEFAULT 0,
  agent_version           VARCHAR(32) DEFAULT NULL,
  hostname                VARCHAR(255) DEFAULT NULL,
  created_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  INDEX idx_client (client_id),
  INDEX idx_status (status),
  INDEX idx_heartbeat (last_heartbeat DESC),
  INDEX idx_enabled (enabled),
  INDEX idx_client_status (client_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Agent instances running on client infrastructure';

-- Agent configuration table
CREATE TABLE IF NOT EXISTS agent_configs (
  agent_id                   VARCHAR(64) PRIMARY KEY,
  min_savings_percent        DECIMAL(5,2) NOT NULL DEFAULT 10.00,
  risk_threshold             DECIMAL(3,2) NOT NULL DEFAULT 0.70,
  max_switches_per_week      INT NOT NULL DEFAULT 3,
  min_pool_duration_hours    INT NOT NULL DEFAULT 24,
  updated_at                 TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE,
  INDEX idx_updated (updated_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Configuration settings for each agent';

-- Instances table: EC2 instances being managed
CREATE TABLE IF NOT EXISTS instances (
  id                      VARCHAR(64) PRIMARY KEY,
  client_id               VARCHAR(64) NOT NULL,
  agent_id                VARCHAR(64) NULL DEFAULT NULL,
  instance_type           VARCHAR(64) NOT NULL,
  region                  VARCHAR(32) NOT NULL,
  az                      VARCHAR(32) NOT NULL,
  ami_id                  VARCHAR(64) DEFAULT NULL,
  root_volume_id          VARCHAR(64) DEFAULT NULL,
  current_mode            VARCHAR(16) NOT NULL DEFAULT 'spot',
  current_pool_id         VARCHAR(128) DEFAULT NULL,
  spot_price              DECIMAL(12,6) DEFAULT NULL,
  ondemand_price          DECIMAL(12,6) DEFAULT NULL,
  baseline_ondemand_price DECIMAL(12,6) DEFAULT NULL,
  installed_at            TIMESTAMP NOT NULL,
  terminated_at           TIMESTAMP NULL DEFAULT NULL,
  is_active               BOOLEAN NOT NULL DEFAULT TRUE,
  last_switch_at          TIMESTAMP NULL DEFAULT NULL,
  created_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE SET NULL,
  INDEX idx_client (client_id),
  INDEX idx_agent (agent_id),
  INDEX idx_active (is_active),
  INDEX idx_region_type (region, instance_type),
  INDEX idx_mode (current_mode),
  INDEX idx_last_switch (last_switch_at DESC),
  INDEX idx_client_active (client_id, is_active),
  INDEX idx_active_client_type (is_active, client_id, instance_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='EC2 instances being managed by the system';

-- Spot pools table: Available spot instance pools
CREATE TABLE IF NOT EXISTS spot_pools (
  id                VARCHAR(128) PRIMARY KEY,
  instance_type     VARCHAR(64) NOT NULL,
  region            VARCHAR(32) NOT NULL,
  az                VARCHAR(32) NOT NULL,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  
  INDEX idx_region_type (region, instance_type),
  INDEX idx_az (az),
  INDEX idx_type_region_az (instance_type, region, az)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Available spot instance pools across regions and AZs';

-- Spot price snapshots: Time-series pricing data
CREATE TABLE IF NOT EXISTS spot_price_snapshots (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  pool_id         VARCHAR(128) NOT NULL,
  price           DECIMAL(12,6) NOT NULL,
  captured_at     TIMESTAMP NOT NULL,
  
  FOREIGN KEY (pool_id) REFERENCES spot_pools(id) ON DELETE CASCADE,
  INDEX idx_pool_time (pool_id, captured_at DESC),
  INDEX idx_captured (captured_at DESC),
  INDEX idx_pool_price (pool_id, price)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Historical spot price data for capacity analysis';

-- On-demand price snapshots
CREATE TABLE IF NOT EXISTS ondemand_price_snapshots (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  region          VARCHAR(32) NOT NULL,
  instance_type   VARCHAR(64) NOT NULL,
  price           DECIMAL(12,6) NOT NULL,
  captured_at     TIMESTAMP NOT NULL,
  
  INDEX idx_region_type_time (region, instance_type, captured_at DESC),
  INDEX idx_captured (captured_at DESC),
  INDEX idx_region_type (region, instance_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Historical on-demand price data for baseline calculations';

-- Risk scores table: ML model output
CREATE TABLE IF NOT EXISTS risk_scores (
  id                        BIGINT AUTO_INCREMENT PRIMARY KEY,
  client_id                 VARCHAR(64) NOT NULL,
  instance_id               VARCHAR(64) NOT NULL,
  agent_id                  VARCHAR(64) NULL DEFAULT NULL,
  risk_score                DECIMAL(5,4) NOT NULL,
  recommended_action        VARCHAR(32) NOT NULL,
  recommended_pool_id       VARCHAR(128) NULL DEFAULT NULL,
  recommended_mode          VARCHAR(16) NOT NULL,
  expected_savings_per_hour DECIMAL(12,6) DEFAULT NULL,
  allowed                   BOOLEAN NOT NULL DEFAULT TRUE,
  reason                    TEXT,
  created_at                TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  FOREIGN KEY (instance_id) REFERENCES instances(id) ON DELETE CASCADE,
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE SET NULL,
  INDEX idx_client_time (client_id, created_at DESC),
  INDEX idx_instance_time (instance_id, created_at DESC),
  INDEX idx_risk_score (risk_score),
  INDEX idx_action (recommended_action),
  INDEX idx_created (created_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Risk assessment results from ML models';

-- Switch events table: Historical instance mode changes
CREATE TABLE IF NOT EXISTS switch_events (
  id                    BIGINT AUTO_INCREMENT PRIMARY KEY,
  client_id             VARCHAR(64) NOT NULL,
  instance_id           VARCHAR(64) NOT NULL,
  agent_id              VARCHAR(64) NULL DEFAULT NULL,
  event_trigger         VARCHAR(16) NOT NULL COMMENT 'Renamed from trigger (reserved keyword)',
  from_mode             VARCHAR(16) DEFAULT NULL,
  to_mode               VARCHAR(16) NOT NULL,
  from_pool_id          VARCHAR(128) DEFAULT NULL,
  to_pool_id            VARCHAR(128) DEFAULT NULL,
  on_demand_price       DECIMAL(12,6) DEFAULT NULL,
  old_spot_price        DECIMAL(12,6) DEFAULT NULL,
  new_spot_price        DECIMAL(12,6) DEFAULT NULL,
  savings_impact        DECIMAL(12,6) DEFAULT NULL,
  snapshot_used         BOOLEAN DEFAULT FALSE,
  snapshot_id           VARCHAR(64) DEFAULT NULL,
  old_instance_id       VARCHAR(64) DEFAULT NULL,
  new_instance_id       VARCHAR(64) DEFAULT NULL,
  timestamp             TIMESTAMP NOT NULL,
  created_at            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE SET NULL,
  INDEX idx_client_time (client_id, timestamp DESC),
  INDEX idx_instance (instance_id),
  INDEX idx_trigger (event_trigger),
  INDEX idx_timestamp (timestamp DESC),
  INDEX idx_old_instance (old_instance_id),
  INDEX idx_new_instance (new_instance_id),
  INDEX idx_client_timestamp_trigger (client_id, timestamp DESC, event_trigger),
  INDEX idx_agent_timestamp (agent_id, timestamp DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='History of instance mode switches (spot/on-demand)';

-- Monthly savings aggregation
CREATE TABLE IF NOT EXISTS client_savings_monthly (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  client_id       VARCHAR(64) NOT NULL,
  year            INT NOT NULL,
  month           INT NOT NULL,
  baseline_cost   DECIMAL(18,4) NOT NULL DEFAULT 0.0000,
  actual_cost     DECIMAL(18,4) NOT NULL DEFAULT 0.0000,
  savings         DECIMAL(18,4) NOT NULL DEFAULT 0.0000,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  UNIQUE KEY uk_client_year_month (client_id, year, month),
  INDEX idx_client (client_id),
  INDEX idx_year_month (year DESC, month DESC),
  INDEX idx_client_year_month (client_id, year DESC, month DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Monthly savings aggregation for reporting';

-- System events log
CREATE TABLE IF NOT EXISTS system_events (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  event_type      VARCHAR(32) NOT NULL,
  severity        VARCHAR(16) NOT NULL,
  client_id       VARCHAR(64) NULL DEFAULT NULL,
  agent_id        VARCHAR(64) NULL DEFAULT NULL,
  instance_id     VARCHAR(64) NULL DEFAULT NULL,
  message         TEXT NOT NULL,
  metadata        JSON DEFAULT NULL,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE SET NULL,
  INDEX idx_type (event_type),
  INDEX idx_severity (severity),
  INDEX idx_created (created_at DESC),
  INDEX idx_client (client_id),
  INDEX idx_type_severity (event_type, severity),
  INDEX idx_client_created (client_id, created_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='System-wide event log for monitoring and debugging';

-- Pending switch commands
CREATE TABLE IF NOT EXISTS pending_switch_commands (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  agent_id        VARCHAR(64) NOT NULL,
  instance_id     VARCHAR(64) NOT NULL,
  target_mode     VARCHAR(16) NOT NULL,
  target_pool_id  VARCHAR(128) NULL DEFAULT NULL,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  executed_at     TIMESTAMP NULL DEFAULT NULL,
  
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE,
  INDEX idx_agent_executed (agent_id, executed_at),
  INDEX idx_created (created_at DESC),
  INDEX idx_instance (instance_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Queue of pending switch operations for agents to execute';

-- ============================================================================
-- SAMPLE DATA (Compatible with setup script)
-- ============================================================================

INSERT INTO clients (id, name, status, client_token, total_savings, last_sync_at) VALUES
  ('client-001', 'TechCorp Solutions', 'active', 'token-techcorp-12345', 12050.7500, NOW()),
  ('client-002', 'Fintech Innovators', 'active', 'token-fintech-67890', 25300.2000, DATE_SUB(NOW(), INTERVAL 5 MINUTE)),
  ('client-003', 'E-commerce Giants', 'active', 'token-ecommerce-11111', 18000.0000, DATE_SUB(NOW(), INTERVAL 10 MINUTE)),
  ('client-004', 'HealthData AI', 'active', 'token-healthdata-22222', 7500.5000, DATE_SUB(NOW(), INTERVAL 15 MINUTE))
ON DUPLICATE KEY UPDATE 
  name = VALUES(name),
  status = VALUES(status),
  total_savings = VALUES(total_savings);

INSERT INTO agents (id, client_id, status, enabled, auto_switch_enabled, auto_terminate_enabled, last_heartbeat, instance_count, agent_version, hostname) VALUES
  ('agent-1a', 'client-001', 'online', TRUE, TRUE, TRUE, NOW(), 5, '1.1.0', 'prod-web-01'),
  ('agent-1b', 'client-001', 'online', TRUE, TRUE, TRUE, DATE_SUB(NOW(), INTERVAL 2 MINUTE), 8, '1.1.0', 'prod-web-02'),
  ('agent-1c', 'client-001', 'online', TRUE, TRUE, FALSE, DATE_SUB(NOW(), INTERVAL 1 MINUTE), 7, '1.1.0', 'prod-web-03'),
  ('agent-1d', 'client-001', 'online', FALSE, FALSE, FALSE, DATE_SUB(NOW(), INTERVAL 3 MINUTE), 5, '1.0.0', 'prod-web-04'),
  ('agent-2a', 'client-002', 'online', TRUE, TRUE, TRUE, NOW(), 10, '1.1.0', 'fin-app-01'),
  ('agent-2b', 'client-002', 'offline', TRUE, TRUE, TRUE, DATE_SUB(NOW(), INTERVAL 1 HOUR), 15, '1.0.0', 'fin-app-02'),
  ('agent-2c', 'client-002', 'online', TRUE, TRUE, TRUE, DATE_SUB(NOW(), INTERVAL 5 MINUTE), 25, '1.1.0', 'fin-app-03')
ON DUPLICATE KEY UPDATE 
  status = VALUES(status), 
  last_heartbeat = VALUES(last_heartbeat),
  instance_count = VALUES(instance_count);

INSERT INTO agent_configs (agent_id, min_savings_percent, risk_threshold, max_switches_per_week, min_pool_duration_hours) VALUES
  ('agent-1a', 10.00, 0.70, 3, 24),
  ('agent-1b', 15.00, 0.75, 2, 48),
  ('agent-1c', 10.00, 0.70, 3, 24),
  ('agent-1d', 10.00, 0.70, 3, 24),
  ('agent-2a', 12.00, 0.65, 4, 24),
  ('agent-2b', 10.00, 0.70, 3, 24),
  ('agent-2c', 10.00, 0.70, 3, 24)
ON DUPLICATE KEY UPDATE 
  min_savings_percent = VALUES(min_savings_percent),
  risk_threshold = VALUES(risk_threshold);

INSERT INTO instances (id, client_id, agent_id, instance_type, region, az, ami_id, current_mode, current_pool_id, spot_price, ondemand_price, baseline_ondemand_price, installed_at, is_active) VALUES
  ('i-12345abc', 'client-001', 'agent-1a', 't3.medium', 'ap-south-1', 'ap-south-1a', 'ami-12345', 'spot', 't3.medium_apsouth1a', 0.012400, 0.041600, 0.041600, DATE_SUB(NOW(), INTERVAL 2 HOUR), TRUE),
  ('i-67890def', 'client-001', 'agent-1a', 'm5.large', 'ap-south-1', 'ap-south-1b', 'ami-67890', 'ondemand', NULL, 0.096000, 0.096000, 0.096000, DATE_SUB(NOW(), INTERVAL 1 DAY), TRUE),
  ('i-abc12345', 'client-001', 'agent-1b', 't3.medium', 'ap-south-1', 'ap-south-1a', 'ami-abc12', 'spot', 't3.medium_apsouth1a', 0.012400, 0.041600, 0.041600, DATE_SUB(NOW(), INTERVAL 5 HOUR), TRUE),
  ('i-xyz78901', 'client-002', 'agent-2a', 'c5.xlarge', 'ap-south-1', 'ap-south-1a', 'ami-xyz78', 'spot', 'c5.xlarge_apsouth1a', 0.078000, 0.170000, 0.170000, DATE_SUB(NOW(), INTERVAL 30 MINUTE), TRUE)
ON DUPLICATE KEY UPDATE 
  is_active = VALUES(is_active),
  spot_price = VALUES(spot_price);

INSERT INTO spot_pools (id, instance_type, region, az) VALUES
  ('t3.medium_apsouth1a', 't3.medium', 'ap-south-1', 'ap-south-1a'),
  ('t3.medium_apsouth1b', 't3.medium', 'ap-south-1', 'ap-south-1b'),
  ('t3.medium_apsouth1c', 't3.medium', 'ap-south-1', 'ap-south-1c'),
  ('m5.large_apsouth1a', 'm5.large', 'ap-south-1', 'ap-south-1a'),
  ('m5.large_apsouth1b', 'm5.large', 'ap-south-1', 'ap-south-1b'),
  ('c5.xlarge_apsouth1a', 'c5.xlarge', 'ap-south-1', 'ap-south-1a'),
  ('c5.xlarge_apsouth1b', 'c5.xlarge', 'ap-south-1', 'ap-south-1b')
ON DUPLICATE KEY UPDATE 
  instance_type = VALUES(instance_type);

INSERT INTO spot_price_snapshots (pool_id, price, captured_at) VALUES
  ('t3.medium_apsouth1a', 0.012400, NOW()),
  ('t3.medium_apsouth1a', 0.012200, DATE_SUB(NOW(), INTERVAL 10 MINUTE)),
  ('t3.medium_apsouth1a', 0.012600, DATE_SUB(NOW(), INTERVAL 20 MINUTE)),
  ('t3.medium_apsouth1b', 0.013000, NOW()),
  ('t3.medium_apsouth1b', 0.012800, DATE_SUB(NOW(), INTERVAL 10 MINUTE)),
  ('t3.medium_apsouth1c', 0.012800, NOW()),
  ('m5.large_apsouth1a', 0.045000, NOW()),
  ('m5.large_apsouth1b', 0.048000, NOW()),
  ('c5.xlarge_apsouth1a', 0.078000, NOW()),
  ('c5.xlarge_apsouth1b', 0.081000, NOW());

INSERT INTO ondemand_price_snapshots (region, instance_type, price, captured_at) VALUES
  ('ap-south-1', 't3.medium', 0.041600, NOW()),
  ('ap-south-1', 'm5.large', 0.096000, NOW()),
  ('ap-south-1', 'c5.xlarge', 0.170000, NOW());

INSERT INTO switch_events (client_id, instance_id, agent_id, event_trigger, from_mode, to_mode, from_pool_id, to_pool_id, on_demand_price, old_spot_price, new_spot_price, savings_impact, snapshot_used, snapshot_id, old_instance_id, new_instance_id, timestamp) VALUES
  ('client-001', 'i-12345abc', 'agent-1a', 'model', 'ondemand', 'spot', NULL, 't3.medium_apsouth1a', 0.041600, 0.041600, 0.012400, 0.029200, TRUE, 'snap-12345', 'i-old123', 'i-12345abc', DATE_SUB(NOW(), INTERVAL 2 HOUR)),
  ('client-001', 'i-67890def', 'agent-1a', 'manual', 'spot', 'ondemand', 'm5.large_apsouth1b', NULL, 0.096000, 0.038000, 0.096000, -0.058000, FALSE, NULL, 'i-old456', 'i-67890def', DATE_SUB(NOW(), INTERVAL 1 DAY)),
  ('client-001', 'i-abc12345', 'agent-1b', 'model', 'spot', 'spot', 't3.medium_apsouth1b', 't3.medium_apsouth1a', 0.041600, 0.013000, 0.012400, 0.000600, TRUE, 'snap-67890', 'i-old789', 'i-abc12345', DATE_SUB(NOW(), INTERVAL 5 HOUR)),
  ('client-002', 'i-xyz78901', 'agent-2a', 'model', 'ondemand', 'spot', NULL, 'c5.xlarge_apsouth1a', 0.170000, 0.170000, 0.078000, 0.092000, TRUE, 'snap-abc12', 'i-old111', 'i-xyz78901', DATE_SUB(NOW(), INTERVAL 30 MINUTE));

INSERT INTO client_savings_monthly (client_id, year, month, baseline_cost, actual_cost, savings) VALUES
  ('client-001', 2025, 1, 6000.0000, 2000.0000, 4000.0000),
  ('client-001', 2025, 2, 5500.0000, 2500.0000, 3000.0000),
  ('client-001', 2025, 3, 7000.0000, 2000.0000, 5000.0000),
  ('client-001', 2025, 4, 6800.0000, 2300.0000, 4500.0000),
  ('client-001', 2025, 5, 8000.0000, 2000.0000, 6000.0000),
  ('client-001', 2025, 6, 7900.0000, 2100.0000, 5800.0000),
  ('client-002', 2025, 1, 10000.0000, 5000.0000, 5000.0000),
  ('client-002', 2025, 2, 11000.0000, 4500.0000, 6500.0000),
  ('client-002', 2025, 3, 10500.0000, 4800.0000, 5700.0000),
  ('client-002', 2025, 4, 11200.0000, 4300.0000, 6900.0000)
ON DUPLICATE KEY UPDATE 
  baseline_cost = VALUES(baseline_cost), 
  actual_cost = VALUES(actual_cost), 
  savings = VALUES(savings);

INSERT INTO system_events (event_type, severity, client_id, agent_id, instance_id, message, metadata) VALUES
  ('agent_registered', 'info', 'client-001', 'agent-1a', 'i-12345abc', 'Agent agent-1a registered successfully', JSON_OBJECT('instance_type', 't3.medium', 'version', '1.1.0')),
  ('switch_completed', 'info', 'client-001', 'agent-1a', 'i-12345abc', 'Instance switched from ondemand to spot', JSON_OBJECT('savings_impact', 0.0292, 'event_trigger', 'model')),
  ('manual_switch_requested', 'info', 'client-001', 'agent-1a', 'i-67890def', 'Manual switch requested via dashboard', JSON_OBJECT('target', 'ondemand')),
  ('savings_computed', 'info', NULL, NULL, NULL, 'Monthly savings computed for 4 clients', JSON_OBJECT('year', 2025, 'month', 11));

-- ============================================================================
-- VIEWS
-- ============================================================================

CREATE OR REPLACE VIEW v_active_instances AS
SELECT 
  i.*,
  c.name as client_name,
  a.status as agent_status,
  (i.ondemand_price - COALESCE(i.spot_price, 0)) as potential_savings,
  CASE 
    WHEN i.current_mode = 'spot' AND i.ondemand_price > 0 
    THEN ((i.ondemand_price - COALESCE(i.spot_price, 0)) / i.ondemand_price * 100)
    ELSE 0.00
  END as savings_percent
FROM instances i
JOIN clients c ON c.id = i.client_id
LEFT JOIN agents a ON a.id = i.agent_id
WHERE i.is_active = TRUE;

CREATE OR REPLACE VIEW v_client_summary AS
SELECT 
  c.id,
  c.name,
  c.status,
  c.total_savings,
  c.last_sync_at,
  COUNT(DISTINCT CASE WHEN a.status = 'online' THEN a.id END) as agents_online,
  COUNT(DISTINCT a.id) as agents_total,
  COUNT(DISTINCT CASE WHEN i.is_active = TRUE THEN i.id END) as active_instances,
  COUNT(DISTINCT CASE WHEN i.current_mode = 'spot' AND i.is_active = TRUE THEN i.id END) as spot_instances,
  COALESCE(SUM(CASE WHEN i.is_active = TRUE THEN (i.ondemand_price - COALESCE(i.spot_price, 0)) * 24 * 30 END), 0) as monthly_savings_estimate
FROM clients c
LEFT JOIN agents a ON a.client_id = c.id
LEFT JOIN instances i ON i.client_id = c.id
GROUP BY c.id, c.name, c.status, c.total_savings, c.last_sync_at;

CREATE OR REPLACE VIEW v_recent_switches AS
SELECT 
  se.*,
  c.name as client_name,
  i.instance_type,
  TIMESTAMPDIFF(
    HOUR, 
    LAG(se.timestamp) OVER (PARTITION BY se.instance_id ORDER BY se.timestamp), 
    se.timestamp
  ) as hours_since_last_switch
FROM switch_events se
JOIN clients c ON c.id = se.client_id
LEFT JOIN instances i ON i.id = se.instance_id
WHERE se.timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY)
ORDER BY se.timestamp DESC;

-- ============================================================================
-- STORED PROCEDURES
-- ============================================================================

DELIMITER //

CREATE PROCEDURE calculate_monthly_savings(
  IN p_client_id VARCHAR(64), 
  IN p_year INT, 
  IN p_month INT
)
BEGIN
  DECLARE v_baseline_cost DECIMAL(18,4) DEFAULT 0.0000;
  DECLARE v_actual_cost DECIMAL(18,4) DEFAULT 0.0000;
  DECLARE v_savings DECIMAL(18,4) DEFAULT 0.0000;
  DECLARE v_hours_in_month INT;
  
  SET v_hours_in_month = DAY(LAST_DAY(CONCAT(p_year, '-', LPAD(p_month, 2, '0'), '-01'))) * 24;
  
  -- Calculate baseline cost
  SELECT COALESCE(SUM(baseline_ondemand_price * v_hours_in_month), 0) INTO v_baseline_cost
  FROM instances
  WHERE client_id = p_client_id
    AND is_active = TRUE
    AND baseline_ondemand_price IS NOT NULL
    AND YEAR(installed_at) <= p_year
    AND (YEAR(installed_at) < p_year OR MONTH(installed_at) <= p_month);
  
  -- Calculate actual cost from switch events
  SELECT COALESCE(SUM(
    CASE 
      WHEN to_mode = 'spot' THEN COALESCE(new_spot_price, 0) * TIMESTAMPDIFF(HOUR, timestamp, COALESCE(
        LEAD(timestamp) OVER (PARTITION BY instance_id ORDER BY timestamp),
        LAST_DAY(CONCAT(p_year, '-', LPAD(p_month, 2, '0'), '-01')) + INTERVAL 1 DAY
      ))
      ELSE COALESCE(on_demand_price, 0) * TIMESTAMPDIFF(HOUR, timestamp, COALESCE(
        LEAD(timestamp) OVER (PARTITION BY instance_id ORDER BY timestamp),
        LAST_DAY(CONCAT(p_year, '-', LPAD(p_month, 2, '0'), '-01')) + INTERVAL 1 DAY
      ))
    END
  ), 0) INTO v_actual_cost
  FROM switch_events
  WHERE client_id = p_client_id
    AND YEAR(timestamp) = p_year
    AND MONTH(timestamp) = p_month;
  
  SET v_savings = v_baseline_cost - v_actual_cost;
  
  -- Insert or update monthly savings
  INSERT INTO client_savings_monthly (client_id, year, month, baseline_cost, actual_cost, savings)
  VALUES (p_client_id, p_year, p_month, v_baseline_cost, v_actual_cost, v_savings)
  ON DUPLICATE KEY UPDATE
    baseline_cost = VALUES(baseline_cost),
    actual_cost = VALUES(actual_cost),
    savings = VALUES(savings),
    updated_at = CURRENT_TIMESTAMP;
END//

CREATE PROCEDURE cleanup_old_data()
BEGIN
  DECLARE v_deleted_snapshots INT DEFAULT 0;
  DECLARE v_deleted_risk_scores INT DEFAULT 0;
  DECLARE v_deleted_system_events INT DEFAULT 0;
  
  -- Clean spot price snapshots
  DELETE FROM spot_price_snapshots 
  WHERE captured_at < DATE_SUB(NOW(), INTERVAL 30 DAY);
  SET v_deleted_snapshots = ROW_COUNT();
  
  -- Clean on-demand price snapshots
  DELETE FROM ondemand_price_snapshots 
  WHERE captured_at < DATE_SUB(NOW(), INTERVAL 30 DAY);
  SET v_deleted_snapshots = v_deleted_snapshots + ROW_COUNT();
  
  -- Clean old risk scores
  DELETE FROM risk_scores 
  WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY);
  SET v_deleted_risk_scores = ROW_COUNT();
  
  -- Clean old system events (keep errors and critical)
  DELETE FROM system_events 
  WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY)
    AND severity NOT IN ('critical', 'error');
  SET v_deleted_system_events = ROW_COUNT();
  
  -- Log cleanup completion
  INSERT INTO system_events (event_type, severity, message, metadata)
  VALUES ('data_cleanup_completed', 'info', 'Cleanup job completed successfully', 
          JSON_OBJECT(
            'deleted_snapshots', v_deleted_snapshots,
            'deleted_risk_scores', v_deleted_risk_scores,
            'deleted_system_events', v_deleted_system_events
          ));
END//

CREATE PROCEDURE get_agent_statistics(IN p_agent_id VARCHAR(64))
BEGIN
  SELECT 
    a.id,
    a.status,
    a.enabled,
    a.auto_switch_enabled,
    a.auto_terminate_enabled,
    a.last_heartbeat,
    a.instance_count,
    COUNT(DISTINCT i.id) as managed_instances,
    COUNT(DISTINCT CASE WHEN se.timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY) THEN se.id END) as switches_last_7_days,
    COUNT(DISTINCT CASE WHEN se.timestamp >= DATE_SUB(NOW(), INTERVAL 30 DAY) THEN se.id END) as switches_last_30_days,
    COALESCE(SUM(CASE WHEN se.timestamp >= DATE_SUB(NOW(), INTERVAL 30 DAY) THEN se.savings_impact ELSE 0 END), 0) as savings_last_30_days
  FROM agents a
  LEFT JOIN instances i ON i.agent_id = a.id AND i.is_active = TRUE
  LEFT JOIN switch_events se ON se.agent_id = a.id
  WHERE a.id = p_agent_id
  GROUP BY a.id, a.status, a.enabled, a.auto_switch_enabled, a.auto_terminate_enabled, 
           a.last_heartbeat, a.instance_count;
END//

CREATE PROCEDURE get_pending_commands_for_agent(IN p_agent_id VARCHAR(64))
BEGIN
  SELECT 
    psc.*,
    i.instance_type,
    i.current_mode,
    i.current_pool_id
  FROM pending_switch_commands psc
  LEFT JOIN instances i ON i.id = psc.instance_id
  WHERE psc.agent_id = p_agent_id
    AND psc.executed_at IS NULL
  ORDER BY psc.created_at ASC;
END//

CREATE PROCEDURE check_switch_frequency_limit(
  IN p_agent_id VARCHAR(64),
  IN p_max_switches_per_week INT,
  OUT p_can_switch BOOLEAN,
  OUT p_current_count INT
)
BEGIN
  SELECT COUNT(*) INTO p_current_count
  FROM switch_events
  WHERE agent_id = p_agent_id
    AND timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY);
  
  SET p_can_switch = (p_current_count < p_max_switches_per_week);
END//

CREATE PROCEDURE archive_switch_events(IN p_days_to_keep INT)
BEGIN
  DECLARE v_archived_count INT DEFAULT 0;
  
  -- Create archive table if not exists
  CREATE TABLE IF NOT EXISTS switch_events_archive LIKE switch_events;
  
  -- Archive old events
  INSERT INTO switch_events_archive
  SELECT * FROM switch_events
  WHERE timestamp < DATE_SUB(NOW(), INTERVAL p_days_to_keep DAY);
  
  SET v_archived_count = ROW_COUNT();
  
  -- Delete archived events from main table
  DELETE FROM switch_events
  WHERE timestamp < DATE_SUB(NOW(), INTERVAL p_days_to_keep DAY);
  
  -- Log archival
  INSERT INTO system_events (event_type, severity, message, metadata)
  VALUES ('switch_events_archived', 'info', 
          CONCAT('Archived ', v_archived_count, ' switch events'),
          JSON_OBJECT('archived_count', v_archived_count, 'days_kept', p_days_to_keep));
END//

DELIMITER ;

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

DELIMITER //

CREATE FUNCTION calculate_savings_percent(
  spot_price DECIMAL(12,6),
  ondemand_price DECIMAL(12,6)
)
RETURNS DECIMAL(5,2)
DETERMINISTIC
BEGIN
  IF ondemand_price > 0 THEN
    RETURN ROUND(((ondemand_price - spot_price) / ondemand_price) * 100, 2);
  ELSE
    RETURN 0.00;
  END IF;
END//

CREATE FUNCTION get_agent_uptime_hours(p_agent_id VARCHAR(64))
RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_created_at TIMESTAMP;
  DECLARE v_uptime_hours INT;
  
  SELECT created_at INTO v_created_at
  FROM agents
  WHERE id = p_agent_id;
  
  IF v_created_at IS NULL THEN
    RETURN 0;
  END IF;
  
  SET v_uptime_hours = TIMESTAMPDIFF(HOUR, v_created_at, NOW());
  
  RETURN v_uptime_hours;
END//

DELIMITER ;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

DELIMITER //

CREATE TRIGGER trg_switch_event_update_savings
AFTER INSERT ON switch_events
FOR EACH ROW
BEGIN
  IF NEW.savings_impact > 0 THEN
    UPDATE clients
    SET total_savings = total_savings + (NEW.savings_impact * 24 * 30)
    WHERE id = NEW.client_id;
  END IF;
END//

CREATE TRIGGER trg_agent_status_change
AFTER UPDATE ON agents
FOR EACH ROW
BEGIN
  IF OLD.status <> NEW.status THEN
    INSERT INTO system_events (event_type, severity, client_id, agent_id, message, metadata)
    VALUES ('agent_status_changed', 'info', NEW.client_id, NEW.id,
            CONCAT('Agent status changed from ', OLD.status, ' to ', NEW.status),
            JSON_OBJECT('old_status', OLD.status, 'new_status', NEW.status));
  END IF;
END//

CREATE TRIGGER trg_instance_validate_baseline
BEFORE INSERT ON instances
FOR EACH ROW
BEGIN
  IF NEW.baseline_ondemand_price IS NULL AND NEW.ondemand_price IS NOT NULL THEN
    SET NEW.baseline_ondemand_price = NEW.ondemand_price;
  END IF;
END//

DELIMITER ;

-- ============================================================================
-- SCHEDULED EVENTS
-- ============================================================================

-- Enable event scheduler
SET GLOBAL event_scheduler = ON;

-- Daily cleanup event
CREATE EVENT IF NOT EXISTS evt_daily_cleanup
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 2 HOUR)
DO
  CALL cleanup_old_data();

-- Monthly savings computation
DELIMITER //

CREATE EVENT IF NOT EXISTS evt_monthly_savings_computation
ON SCHEDULE EVERY 1 MONTH
STARTS (DATE_ADD(DATE_ADD(LAST_DAY(CURRENT_DATE), INTERVAL 1 DAY), INTERVAL 1 HOUR))
DO
BEGIN
  DECLARE done INT DEFAULT FALSE;
  DECLARE v_client_id VARCHAR(64);
  DECLARE v_year INT;
  DECLARE v_month INT;
  DECLARE cur CURSOR FOR SELECT id FROM clients WHERE status = 'active';
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
  
  SET v_year = YEAR(DATE_SUB(CURRENT_DATE, INTERVAL 1 MONTH));
  SET v_month = MONTH(DATE_SUB(CURRENT_DATE, INTERVAL 1 MONTH));
  
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO v_client_id;
    IF done THEN
      LEAVE read_loop;
    END IF;
    
    CALL calculate_monthly_savings(v_client_id, v_year, v_month);
  END LOOP;
  CLOSE cur;
END//

-- Quarterly archive event
CREATE EVENT IF NOT EXISTS evt_quarterly_archive
ON SCHEDULE EVERY 3 MONTH
STARTS (DATE_ADD(DATE_ADD(LAST_DAY(CURRENT_DATE), INTERVAL 1 DAY), INTERVAL 3 HOUR))
DO
  CALL archive_switch_events(180);
//

DELIMITER ;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Show table stats
SELECT 
  TABLE_NAME,
  TABLE_ROWS,
  ROUND(DATA_LENGTH / 1024 / 1024, 2) as DATA_MB,
  ROUND(INDEX_LENGTH / 1024 / 1024, 2) as INDEX_MB
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'spot_optimizer'
ORDER BY TABLE_NAME;

-- Show views
SELECT TABLE_NAME 
FROM information_schema.VIEWS 
WHERE TABLE_SCHEMA = 'spot_optimizer';

-- Show stored procedures and functions
SELECT ROUTINE_NAME, ROUTINE_TYPE 
FROM information_schema.ROUTINES 
WHERE ROUTINE_SCHEMA = 'spot_optimizer'
ORDER BY ROUTINE_TYPE, ROUTINE_NAME;

-- Show triggers
SELECT TRIGGER_NAME, EVENT_MANIPULATION, EVENT_OBJECT_TABLE
FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = 'spot_optimizer'
ORDER BY EVENT_OBJECT_TABLE, TRIGGER_NAME;

-- Show scheduled events
SELECT EVENT_NAME, STATUS, EVENT_TYPE, INTERVAL_VALUE, INTERVAL_FIELD
FROM information_schema.EVENTS
WHERE EVENT_SCHEMA = 'spot_optimizer'
ORDER BY EVENT_NAME;

-- ============================================================================
-- OPTIMIZATION: ANALYZE TABLES
-- ============================================================================

ANALYZE TABLE clients;
ANALYZE TABLE agents;
ANALYZE TABLE agent_configs;
ANALYZE TABLE instances;
ANALYZE TABLE spot_pools;
ANALYZE TABLE spot_price_snapshots;
ANALYZE TABLE ondemand_price_snapshots;
ANALYZE TABLE risk_scores;
ANALYZE TABLE switch_events;
ANALYZE TABLE client_savings_monthly;
ANALYZE TABLE system_events;
ANALYZE TABLE pending_switch_commands;

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
