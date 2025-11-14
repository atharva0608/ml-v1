-- ============================================================================
-- AWS SPOT OPTIMIZER - DATABASE SCHEMA (FIXED)
-- ============================================================================
-- Production MySQL schema for central server
-- Version: 1.1.0 (Updated to match fixed backend v1.1.0)
-- 
-- Changes from v1.0.0:
-- - Added pending_switch_commands table for force-switch support (P0 FIX #4)
-- - Added indexes for performance optimization
-- - Updated sample data to reflect production scenarios
-- - Added cleanup stored procedures
-- - Enhanced system_events with proper indexes
-- ============================================================================

-- Drop database if exists (CAUTION: Use only for fresh setup)
-- DROP DATABASE IF EXISTS spot_optimizer;

-- Create database
CREATE DATABASE IF NOT EXISTS spot_optimizer
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE spot_optimizer;

-- ============================================================================
-- CLIENTS TABLE
-- ============================================================================
-- Stores customer/client information

CREATE TABLE clients (
  id                VARCHAR(64) PRIMARY KEY,
  name              VARCHAR(255) NOT NULL,
  status            VARCHAR(32) NOT NULL DEFAULT 'active',
  client_token      VARCHAR(255) NOT NULL UNIQUE,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_sync_at      TIMESTAMP NULL,
  total_savings     DECIMAL(18,4) NOT NULL DEFAULT 0,
  
  INDEX idx_status (status),
  INDEX idx_token (client_token),
  INDEX idx_last_sync (last_sync_at),
  INDEX idx_created (created_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- AGENTS TABLE
-- ============================================================================
-- Stores agent processes running on client EC2 instances

CREATE TABLE agents (
  id                      VARCHAR(64) PRIMARY KEY,
  client_id               VARCHAR(64) NOT NULL,
  status                  VARCHAR(32) NOT NULL DEFAULT 'offline',
  enabled                 BOOLEAN NOT NULL DEFAULT TRUE,
  auto_switch_enabled     BOOLEAN NOT NULL DEFAULT TRUE,
  auto_terminate_enabled  BOOLEAN NOT NULL DEFAULT TRUE,
  last_heartbeat          TIMESTAMP NULL,
  instance_count          INT DEFAULT 0,
  agent_version           VARCHAR(32),
  hostname                VARCHAR(255),
  created_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at              TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  INDEX idx_client (client_id),
  INDEX idx_status (status),
  INDEX idx_heartbeat (last_heartbeat DESC),
  INDEX idx_enabled (enabled),
  INDEX idx_client_status (client_id, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- AGENT CONFIGS TABLE
-- ============================================================================
-- Stores per-agent configuration and thresholds

CREATE TABLE agent_configs (
  agent_id                   VARCHAR(64) PRIMARY KEY,
  min_savings_percent        DECIMAL(5,2) NOT NULL DEFAULT 10.0,
  risk_threshold             DECIMAL(3,2) NOT NULL DEFAULT 0.70,
  max_switches_per_week      INT NOT NULL DEFAULT 3,
  min_pool_duration_hours    INT NOT NULL DEFAULT 24,
  updated_at                 TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE,
  INDEX idx_updated (updated_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- INSTANCES TABLE
-- ============================================================================
-- Stores EC2 instances being monitored/managed

CREATE TABLE instances (
  id                      VARCHAR(64) PRIMARY KEY,
  client_id               VARCHAR(64) NOT NULL,
  agent_id                VARCHAR(64) NULL,
  instance_type           VARCHAR(64) NOT NULL,
  region                  VARCHAR(32) NOT NULL,
  az                      VARCHAR(32) NOT NULL,
  ami_id                  VARCHAR(64),
  root_volume_id          VARCHAR(64),
  current_mode            VARCHAR(16) NOT NULL DEFAULT 'spot',
  current_pool_id         VARCHAR(128),
  spot_price              DECIMAL(12,6),
  ondemand_price          DECIMAL(12,6),
  baseline_ondemand_price DECIMAL(12,6),
  installed_at            TIMESTAMP NOT NULL,
  terminated_at           TIMESTAMP NULL,
  is_active               BOOLEAN NOT NULL DEFAULT TRUE,
  last_switch_at          TIMESTAMP NULL,
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- SPOT POOLS TABLE
-- ============================================================================
-- Stores logical spot pools (instance_type + AZ combinations)

CREATE TABLE spot_pools (
  id                VARCHAR(128) PRIMARY KEY,
  instance_type     VARCHAR(64) NOT NULL,
  region            VARCHAR(32) NOT NULL,
  az                VARCHAR(32) NOT NULL,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  
  INDEX idx_region_type (region, instance_type),
  INDEX idx_az (az),
  INDEX idx_type_region_az (instance_type, region, az)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- SPOT PRICE SNAPSHOTS TABLE
-- ============================================================================
-- Time-series data of spot prices

CREATE TABLE spot_price_snapshots (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  pool_id         VARCHAR(128) NOT NULL,
  price           DECIMAL(12,6) NOT NULL,
  captured_at     TIMESTAMP NOT NULL,
  
  FOREIGN KEY (pool_id) REFERENCES spot_pools(id) ON DELETE CASCADE,
  INDEX idx_pool_time (pool_id, captured_at DESC),
  INDEX idx_captured (captured_at DESC),
  INDEX idx_pool_price (pool_id, price)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- ON-DEMAND PRICE SNAPSHOTS TABLE
-- ============================================================================
-- Time-series data of on-demand prices

CREATE TABLE ondemand_price_snapshots (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  region          VARCHAR(32) NOT NULL,
  instance_type   VARCHAR(64) NOT NULL,
  price           DECIMAL(12,6) NOT NULL,
  captured_at     TIMESTAMP NOT NULL,
  
  INDEX idx_region_type_time (region, instance_type, captured_at DESC),
  INDEX idx_captured (captured_at DESC),
  INDEX idx_region_type (region, instance_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- RISK SCORES TABLE
-- ============================================================================
-- Records every decision made by the ML model

CREATE TABLE risk_scores (
  id                        BIGINT AUTO_INCREMENT PRIMARY KEY,
  client_id                 VARCHAR(64) NOT NULL,
  instance_id               VARCHAR(64) NOT NULL,
  agent_id                  VARCHAR(64) NULL,
  risk_score                DECIMAL(5,4) NOT NULL,
  recommended_action        VARCHAR(32) NOT NULL,
  recommended_pool_id       VARCHAR(128) NULL,
  recommended_mode          VARCHAR(16) NOT NULL,
  expected_savings_per_hour DECIMAL(12,6),
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- SWITCH EVENTS TABLE
-- ============================================================================
-- Records all instance switches (model and manual)

CREATE TABLE switch_events (
  id                    BIGINT AUTO_INCREMENT PRIMARY KEY,
  client_id             VARCHAR(64) NOT NULL,
  instance_id           VARCHAR(64) NOT NULL,
  agent_id              VARCHAR(64) NULL,
  trigger               VARCHAR(16) NOT NULL,
  from_mode             VARCHAR(16),
  to_mode               VARCHAR(16) NOT NULL,
  from_pool_id          VARCHAR(128),
  to_pool_id            VARCHAR(128),
  on_demand_price       DECIMAL(12,6),
  old_spot_price        DECIMAL(12,6),
  new_spot_price        DECIMAL(12,6),
  savings_impact        DECIMAL(12,6),
  snapshot_used         BOOLEAN DEFAULT FALSE,
  snapshot_id           VARCHAR(64),
  old_instance_id       VARCHAR(64),
  new_instance_id       VARCHAR(64),
  timestamp             TIMESTAMP NOT NULL,
  created_at            TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE SET NULL,
  INDEX idx_client_time (client_id, timestamp DESC),
  INDEX idx_instance (instance_id),
  INDEX idx_trigger (trigger),
  INDEX idx_timestamp (timestamp DESC),
  INDEX idx_old_instance (old_instance_id),
  INDEX idx_new_instance (new_instance_id),
  INDEX idx_client_timestamp_trigger (client_id, timestamp DESC, trigger),
  INDEX idx_agent_timestamp (agent_id, timestamp DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- CLIENT SAVINGS MONTHLY TABLE
-- ============================================================================
-- Aggregated monthly savings for reporting

CREATE TABLE client_savings_monthly (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  client_id       VARCHAR(64) NOT NULL,
  year            INT NOT NULL,
  month           INT NOT NULL,
  baseline_cost   DECIMAL(18,4) NOT NULL,
  actual_cost     DECIMAL(18,4) NOT NULL,
  savings         DECIMAL(18,4) NOT NULL,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  UNIQUE KEY uk_client_year_month (client_id, year, month),
  INDEX idx_client (client_id),
  INDEX idx_year_month (year DESC, month DESC),
  INDEX idx_client_year_month (client_id, year DESC, month DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- SYSTEM EVENTS TABLE
-- ============================================================================
-- Records system-level events, errors, and notifications

CREATE TABLE system_events (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  event_type      VARCHAR(32) NOT NULL,
  severity        VARCHAR(16) NOT NULL,
  client_id       VARCHAR(64) NULL,
  agent_id        VARCHAR(64) NULL,
  instance_id     VARCHAR(64) NULL,
  message         TEXT NOT NULL,
  metadata        JSON,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE SET NULL,
  INDEX idx_type (event_type),
  INDEX idx_severity (severity),
  INDEX idx_created (created_at DESC),
  INDEX idx_client (client_id),
  INDEX idx_type_severity (event_type, severity),
  INDEX idx_client_created (client_id, created_at DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- PENDING SWITCH COMMANDS TABLE (P0 FIX #4)
-- ============================================================================
-- Stores manual switch commands from dashboard waiting for agent execution

CREATE TABLE pending_switch_commands (
  id              BIGINT AUTO_INCREMENT PRIMARY KEY,
  agent_id        VARCHAR(64) NOT NULL,
  instance_id     VARCHAR(64) NOT NULL,
  target_mode     VARCHAR(16) NOT NULL,
  target_pool_id  VARCHAR(128) NULL,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  executed_at     TIMESTAMP NULL,
  
  FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE,
  INDEX idx_agent_executed (agent_id, executed_at),
  INDEX idx_created (created_at DESC),
  INDEX idx_instance (instance_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- SAMPLE DATA FOR TESTING
-- ============================================================================

-- Insert sample clients
INSERT INTO clients (id, name, status, client_token, total_savings, last_sync_at) VALUES
  ('client-001', 'TechCorp Solutions', 'active', 'token-techcorp-12345', 12050.75, NOW()),
  ('client-002', 'Fintech Innovators', 'active', 'token-fintech-67890', 25300.20, DATE_SUB(NOW(), INTERVAL 5 MINUTE)),
  ('client-003', 'E-commerce Giants', 'active', 'token-ecommerce-11111', 18000.00, DATE_SUB(NOW(), INTERVAL 10 MINUTE)),
  ('client-004', 'HealthData AI', 'active', 'token-healthdata-22222', 7500.50, DATE_SUB(NOW(), INTERVAL 15 MINUTE));

-- Insert sample agents for client-001
INSERT INTO agents (id, client_id, status, enabled, auto_switch_enabled, auto_terminate_enabled, last_heartbeat, instance_count, agent_version, hostname) VALUES
  ('agent-1a', 'client-001', 'online', TRUE, TRUE, TRUE, NOW(), 5, '1.1.0', 'prod-web-01'),
  ('agent-1b', 'client-001', 'online', TRUE, TRUE, TRUE, DATE_SUB(NOW(), INTERVAL 2 MINUTE), 8, '1.1.0', 'prod-web-02'),
  ('agent-1c', 'client-001', 'online', TRUE, TRUE, FALSE, DATE_SUB(NOW(), INTERVAL 1 MINUTE), 7, '1.1.0', 'prod-web-03'),
  ('agent-1d', 'client-001', 'online', FALSE, FALSE, FALSE, DATE_SUB(NOW(), INTERVAL 3 MINUTE), 5, '1.0.0', 'prod-web-04');

-- Insert sample agents for client-002
INSERT INTO agents (id, client_id, status, enabled, auto_switch_enabled, auto_terminate_enabled, last_heartbeat, instance_count, agent_version, hostname) VALUES
  ('agent-2a', 'client-002', 'online', TRUE, TRUE, TRUE, NOW(), 10, '1.1.0', 'fin-app-01'),
  ('agent-2b', 'client-002', 'offline', TRUE, TRUE, TRUE, DATE_SUB(NOW(), INTERVAL 1 HOUR), 15, '1.0.0', 'fin-app-02'),
  ('agent-2c', 'client-002', 'online', TRUE, TRUE, TRUE, DATE_SUB(NOW(), INTERVAL 5 MINUTE), 25, '1.1.0', 'fin-app-03');

-- Insert agent configs
INSERT INTO agent_configs (agent_id, min_savings_percent, risk_threshold, max_switches_per_week, min_pool_duration_hours) VALUES
  ('agent-1a', 10.0, 0.70, 3, 24),
  ('agent-1b', 15.0, 0.75, 2, 48),
  ('agent-1c', 10.0, 0.70, 3, 24),
  ('agent-1d', 10.0, 0.70, 3, 24),
  ('agent-2a', 12.0, 0.65, 4, 24),
  ('agent-2b', 10.0, 0.70, 3, 24),
  ('agent-2c', 10.0, 0.70, 3, 24);

-- Insert sample instances
INSERT INTO instances (id, client_id, agent_id, instance_type, region, az, ami_id, current_mode, current_pool_id, spot_price, ondemand_price, baseline_ondemand_price, installed_at, is_active) VALUES
  ('i-12345abc', 'client-001', 'agent-1a', 't3.medium', 'ap-south-1', 'ap-south-1a', 'ami-12345', 'spot', 't3.medium_apsouth1a', 0.0124, 0.0416, 0.0416, DATE_SUB(NOW(), INTERVAL 2 HOUR), TRUE),
  ('i-67890def', 'client-001', 'agent-1a', 'm5.large', 'ap-south-1', 'ap-south-1b', 'ami-67890', 'ondemand', 'n/a', 0.0960, 0.096, 0.096, DATE_SUB(NOW(), INTERVAL 1 DAY), TRUE),
  ('i-abc12345', 'client-001', 'agent-1b', 't3.medium', 'ap-south-1', 'ap-south-1a', 'ami-abc12', 'spot', 't3.medium_apsouth1a', 0.0124, 0.0416, 0.0416, DATE_SUB(NOW(), INTERVAL 5 HOUR), TRUE),
  ('i-xyz78901', 'client-002', 'agent-2a', 'c5.xlarge', 'ap-south-1', 'ap-south-1a', 'ami-xyz78', 'spot', 'c5.xlarge_apsouth1a', 0.078, 0.17, 0.17, DATE_SUB(NOW(), INTERVAL 30 MINUTE), TRUE);

-- Insert sample spot pools
INSERT INTO spot_pools (id, instance_type, region, az) VALUES
  ('t3.medium_apsouth1a', 't3.medium', 'ap-south-1', 'ap-south-1a'),
  ('t3.medium_apsouth1b', 't3.medium', 'ap-south-1', 'ap-south-1b'),
  ('t3.medium_apsouth1c', 't3.medium', 'ap-south-1', 'ap-south-1c'),
  ('m5.large_apsouth1a', 'm5.large', 'ap-south-1', 'ap-south-1a'),
  ('m5.large_apsouth1b', 'm5.large', 'ap-south-1', 'ap-south-1b'),
  ('c5.xlarge_apsouth1a', 'c5.xlarge', 'ap-south-1', 'ap-south-1a'),
  ('c5.xlarge_apsouth1b', 'c5.xlarge', 'ap-south-1', 'ap-south-1b');

-- Insert sample spot price snapshots
INSERT INTO spot_price_snapshots (pool_id, price, captured_at) VALUES
  ('t3.medium_apsouth1a', 0.0124, NOW()),
  ('t3.medium_apsouth1a', 0.0122, DATE_SUB(NOW(), INTERVAL 10 MINUTE)),
  ('t3.medium_apsouth1a', 0.0126, DATE_SUB(NOW(), INTERVAL 20 MINUTE)),
  ('t3.medium_apsouth1b', 0.0130, NOW()),
  ('t3.medium_apsouth1b', 0.0128, DATE_SUB(NOW(), INTERVAL 10 MINUTE)),
  ('t3.medium_apsouth1c', 0.0128, NOW()),
  ('m5.large_apsouth1a', 0.045, NOW()),
  ('m5.large_apsouth1b', 0.048, NOW()),
  ('c5.xlarge_apsouth1a', 0.078, NOW()),
  ('c5.xlarge_apsouth1b', 0.081, NOW());

-- Insert sample on-demand price snapshots
INSERT INTO ondemand_price_snapshots (region, instance_type, price, captured_at) VALUES
  ('ap-south-1', 't3.medium', 0.0416, NOW()),
  ('ap-south-1', 'm5.large', 0.096, NOW()),
  ('ap-south-1', 'c5.xlarge', 0.17, NOW());

-- Insert sample switch history
INSERT INTO switch_events (client_id, instance_id, agent_id, trigger, from_mode, to_mode, from_pool_id, to_pool_id, on_demand_price, old_spot_price, new_spot_price, savings_impact, snapshot_used, snapshot_id, old_instance_id, new_instance_id, timestamp) VALUES
  ('client-001', 'i-12345abc', 'agent-1a', 'model', 'ondemand', 'spot', 'n/a', 't3.medium_apsouth1a', 0.0416, 0.0416, 0.0124, 0.0292, TRUE, 'snap-12345', 'i-old123', 'i-12345abc', DATE_SUB(NOW(), INTERVAL 2 HOUR)),
  ('client-001', 'i-67890def', 'agent-1a', 'manual', 'spot', 'ondemand', 'm5.large_apsouth1b', 'n/a', 0.096, 0.038, 0.096, -0.058, FALSE, NULL, 'i-old456', 'i-67890def', DATE_SUB(NOW(), INTERVAL 1 DAY)),
  ('client-001', 'i-abc12345', 'agent-1b', 'model', 'spot', 'spot', 't3.medium_apsouth1b', 't3.medium_apsouth1a', 0.0416, 0.0130, 0.0124, 0.0006, TRUE, 'snap-67890', 'i-old789', 'i-abc12345', DATE_SUB(NOW(), INTERVAL 5 HOUR)),
  ('client-002', 'i-xyz78901', 'agent-2a', 'model', 'ondemand', 'spot', 'n/a', 'c5.xlarge_apsouth1a', 0.17, 0.17, 0.078, 0.092, TRUE, 'snap-abc12', 'i-old111', 'i-xyz78901', DATE_SUB(NOW(), INTERVAL 30 MINUTE));

-- Insert sample monthly savings
INSERT INTO client_savings_monthly (client_id, year, month, baseline_cost, actual_cost, savings) VALUES
  ('client-001', 2025, 1, 6000, 2000, 4000),
  ('client-001', 2025, 2, 5500, 2500, 3000),
  ('client-001', 2025, 3, 7000, 2000, 5000),
  ('client-001', 2025, 4, 6800, 2300, 4500),
  ('client-001', 2025, 5, 8000, 2000, 6000),
  ('client-001', 2025, 6, 7900, 2100, 5800),
  ('client-001', 2025, 7, 8200, 1900, 6300),
  ('client-001', 2025, 8, 7800, 2200, 5600),
  ('client-001', 2025, 9, 8100, 2000, 6100),
  ('client-001', 2025, 10, 8300, 1800, 6500),
  ('client-002', 2025, 1, 10000, 5000, 5000),
  ('client-002', 2025, 2, 11000, 4500, 6500),
  ('client-002', 2025, 3, 10500, 4800, 5700),
  ('client-002', 2025, 4, 11200, 4300, 6900);

-- Insert sample system events
INSERT INTO system_events (event_type, severity, client_id, agent_id, instance_id, message, metadata) VALUES
  ('agent_registered', 'info', 'client-001', 'agent-1a', 'i-12345abc', 'Agent agent-1a registered successfully', '{"instance_type": "t3.medium", "version": "1.1.0"}'),
  ('switch_completed', 'info', 'client-001', 'agent-1a', 'i-12345abc', 'Instance switched from ondemand to spot', '{"savings_impact": 0.0292, "trigger": "model"}'),
  ('manual_switch_requested', 'info', 'client-001', 'agent-1a', 'i-67890def', 'Manual switch requested via dashboard', '{"target": "ondemand"}'),
  ('savings_computed', 'info', NULL, NULL, NULL, 'Monthly savings computed for 4 clients', '{"year": 2025, "month": 11}');

-- ============================================================================
-- VIEWS
-- ============================================================================

-- View: Active instances with latest pricing
CREATE OR REPLACE VIEW v_active_instances AS
SELECT 
  i.*,
  c.name as client_name,
  a.status as agent_status,
  (i.ondemand_price - COALESCE(i.spot_price, 0)) as potential_savings,
  CASE 
    WHEN i.current_mode = 'spot' THEN ((i.ondemand_price - i.spot_price) / i.ondemand_price * 100)
    ELSE 0 
  END as savings_percent
FROM instances i
JOIN clients c ON c.id = i.client_id
LEFT JOIN agents a ON a.id = i.agent_id
WHERE i.is_active = TRUE;

-- View: Client summary with aggregated stats
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
  COUNT(DISTINCT CASE WHEN i.current_mode = 'spot' THEN i.id END) as spot_instances,
  SUM(CASE WHEN i.is_active = TRUE THEN (i.ondemand_price - COALESCE(i.spot_price, 0)) * 24 * 30 END) as monthly_savings_estimate
FROM clients c
LEFT JOIN agents a ON a.client_id = c.id
LEFT JOIN instances i ON i.client_id = c.id
GROUP BY c.id, c.name, c.status, c.total_savings, c.last_sync_at;

-- View: Recent switch activity
CREATE OR REPLACE VIEW v_recent_switches AS
SELECT 
  se.*,
  c.name as client_name,
  i.instance_type,
  TIMESTAMPDIFF(HOUR, LAG(se.timestamp) OVER (PARTITION BY se.instance_id ORDER BY se.timestamp), se.timestamp) as hours_since_last_switch
FROM switch_events se
JOIN clients c ON c.id = se.client_id
LEFT JOIN instances i ON i.id = se.instance_id
WHERE se.timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY)
ORDER BY se.timestamp DESC;

-- ============================================================================
-- STORED PROCEDURES
-- ============================================================================

DELIMITER //

-- Procedure: Calculate and update monthly savings
CREATE PROCEDURE calculate_monthly_savings(IN p_client_id VARCHAR(64), IN p_year INT, IN p_month INT)
BEGIN
  DECLARE v_baseline_cost DECIMAL(18,4);
  DECLARE v_actual_cost DECIMAL(18,4);
  DECLARE v_savings DECIMAL(18,4);
  DECLARE v_hours_in_month INT;
  
  -- Calculate hours in month
  SET v_hours_in_month = DAY(LAST_DAY(CONCAT(p_year, '-', p_month, '-01'))) * 24;
  
  -- Calculate baseline (all on-demand) cost from instances baseline prices
  SELECT SUM(baseline_ondemand_price * v_hours_in_month) INTO v_baseline_cost
  FROM instances
  WHERE client_id = p_client_id
    AND is_active = TRUE
    AND baseline_ondemand_price IS NOT NULL
    AND YEAR(installed_at) <= p_year
    AND (YEAR(installed_at) < p_year OR MONTH(installed_at) <= p_month);
  
  -- Calculate actual cost from switch events
  SELECT SUM(
    CASE 
      WHEN to_mode = 'spot' THEN COALESCE(new_spot_price, 0) * TIMESTAMPDIFF(HOUR, timestamp, COALESCE(
        LEAD(timestamp) OVER (PARTITION BY instance_id ORDER BY timestamp),
        LAST_DAY(CONCAT(p_year, '-', p_month, '-01')) + INTERVAL 1 DAY
      ))
      ELSE COALESCE(on_demand_price, 0) * TIMESTAMPDIFF(HOUR, timestamp, COALESCE(
        LEAD(timestamp) OVER (PARTITION BY instance_id ORDER BY timestamp),
        LAST_DAY(CONCAT(p_year, '-', p_month, '-01')) + INTERVAL 1 DAY
      ))
    END
  ) INTO v_actual_cost
  FROM switch_events
  WHERE client_id = p_client_id
    AND YEAR(timestamp) = p_year
    AND MONTH(timestamp) = p_month;
  
  SET v_savings = COALESCE(v_baseline_cost, 0) - COALESCE(v_actual_cost, 0);
  
  -- Upsert into monthly savings table
  INSERT INTO client_savings_monthly (client_id, year, month, baseline_cost, actual_cost, savings)
  VALUES (p_client_id, p_year, p_month, COALESCE(v_baseline_cost, 0), COALESCE(v_actual_cost, 0), v_savings)
  ON DUPLICATE KEY UPDATE
    baseline_cost = VALUES(baseline_cost),
    actual_cost = VALUES(actual_cost),
    savings = VALUES(savings),
    updated_at = CURRENT_TIMESTAMP;
END//

-- Procedure: Cleanup old time-series data
CREATE PROCEDURE cleanup_old_data()
BEGIN
  DECLARE v_deleted_snapshots INT;
  DECLARE v_deleted_risk_scores INT;
  DECLARE v_deleted_system_events INT;
  
  -- Clean up spot price snapshots older than 30 days
  DELETE FROM spot_price_snapshots 
  WHERE captured_at < DATE_SUB(NOW(), INTERVAL 30 DAY);
  SET v_deleted_snapshots = ROW_COUNT();
  
  -- Clean up on-demand price snapshots older than 30 days
  DELETE FROM ondemand_price_snapshots 
  WHERE captured_at < DATE_SUB(NOW(), INTERVAL 30 DAY);
  SET v_deleted_snapshots = v_deleted_snapshots + ROW_COUNT();
  
  -- Clean up risk scores older than 90 days
  DELETE FROM risk_scores 
  WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY);
  SET v_deleted_risk_scores = ROW_COUNT();
  
  -- Clean up system events older than 90 days (except critical errors)
  DELETE FROM system_events 
  WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY)
    AND severity NOT IN ('critical', 'error');
  SET v_deleted_system_events = ROW_COUNT();
  
  -- Log cleanup results
  INSERT INTO system_events (event_type, severity, message, metadata)
  VALUES ('data_cleanup_completed', 'info', 'Cleanup job completed successfully', 
          JSON_OBJECT(
            'deleted_snapshots', v_deleted_snapshots,
            'deleted_risk_scores', v_deleted_risk_scores,
            'deleted_system_events', v_deleted_system_events
          ));
END//

-- Procedure: Get agent statistics
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
    SUM(CASE WHEN se.timestamp >= DATE_SUB(NOW(), INTERVAL 30 DAY) THEN se.savings_impact ELSE 0 END) as savings_last_30_days
  FROM agents a
  LEFT JOIN instances i ON i.agent_id = a.id AND i.is_active = TRUE
  LEFT JOIN switch_events se ON se.agent_id = a.id
  WHERE a.id = p_agent_id
  GROUP BY a.id, a.status, a.enabled, a.auto_switch_enabled, a.auto_terminate_enabled, 
           a.last_heartbeat, a.instance_count;
END//

-- Procedure: Get pending commands for agent
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

-- Procedure: Check switch frequency limit
CREATE PROCEDURE check_switch_frequency_limit(
  IN p_agent_id VARCHAR(64),
  IN p_max_switches_per_week INT,
  OUT p_can_switch BOOLEAN,
  OUT p_current_count INT
)
BEGIN
  -- Count switches in last 7 days
  SELECT COUNT(*) INTO p_current_count
  FROM switch_events
  WHERE agent_id = p_agent_id
    AND timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY);
  
  -- Check if under limit
  SET p_can_switch = (p_current_count < p_max_switches_per_week);
END//

-- Procedure: Archive old switch events
CREATE PROCEDURE archive_switch_events(IN p_days_to_keep INT)
BEGIN
  DECLARE v_archived_count INT;
  
  -- Create archive table if not exists
  CREATE TABLE IF NOT EXISTS switch_events_archive LIKE switch_events;
  
  -- Copy old events to archive
  INSERT INTO switch_events_archive
  SELECT * FROM switch_events
  WHERE timestamp < DATE_SUB(NOW(), INTERVAL p_days_to_keep DAY);
  
  SET v_archived_count = ROW_COUNT();
  
  -- Delete archived events from main table
  DELETE FROM switch_events
  WHERE timestamp < DATE_SUB(NOW(), INTERVAL p_days_to_keep DAY);
  
  -- Log archive operation
  INSERT INTO system_events (event_type, severity, message, metadata)
  VALUES ('switch_events_archived', 'info', 
          CONCAT('Archived ', v_archived_count, ' switch events'),
          JSON_OBJECT('archived_count', v_archived_count, 'days_kept', p_days_to_keep));
END//

DELIMITER ;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Trigger: Update client total_savings after switch event
DELIMITER //

CREATE TRIGGER trg_switch_event_update_savings
AFTER INSERT ON switch_events
FOR EACH ROW
BEGIN
  -- Only update for positive savings impact
  IF NEW.savings_impact > 0 THEN
    -- Estimate hourly savings impact over typical instance lifetime
    UPDATE clients
    SET total_savings = total_savings + (NEW.savings_impact * 24 * 30)
    WHERE id = NEW.client_id;
  END IF;
END//

-- Trigger: Log agent status changes
CREATE TRIGGER trg_agent_status_change
AFTER UPDATE ON agents
FOR EACH ROW
BEGIN
  IF OLD.status != NEW.status THEN
    INSERT INTO system_events (event_type, severity, client_id, agent_id, message, metadata)
    VALUES ('agent_status_changed', 'info', NEW.client_id, NEW.id,
            CONCAT('Agent status changed from ', OLD.status, ' to ', NEW.status),
            JSON_OBJECT('old_status', OLD.status, 'new_status', NEW.status));
  END IF;
END//

-- Trigger: Validate instance baseline price on insert
CREATE TRIGGER trg_instance_validate_baseline
BEFORE INSERT ON instances
FOR EACH ROW
BEGIN
  -- If baseline_ondemand_price is not set, use ondemand_price
  IF NEW.baseline_ondemand_price IS NULL AND NEW.ondemand_price IS NOT NULL THEN
    SET NEW.baseline_ondemand_price = NEW.ondemand_price;
  END IF;
END//

DELIMITER ;

-- ============================================================================
-- UTILITY QUERIES AND FUNCTIONS
-- ============================================================================

-- Function: Calculate savings percentage
DELIMITER //

CREATE FUNCTION calculate_savings_percent(
  spot_price DECIMAL(12,6),
  ondemand_price DECIMAL(12,6)
)
RETURNS DECIMAL(5,2)
DETERMINISTIC
BEGIN
  IF ondemand_price > 0 THEN
    RETURN ((ondemand_price - spot_price) / ondemand_price) * 100;
  ELSE
    RETURN 0;
  END IF;
END//

-- Function: Get agent uptime hours
CREATE FUNCTION get_agent_uptime_hours(p_agent_id VARCHAR(64))
RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_created_at TIMESTAMP;
  DECLARE v_uptime_hours INT;
  
  SELECT created_at INTO v_created_at
  FROM agents
  WHERE id = p_agent_id;
  
  SET v_uptime_hours = TIMESTAMPDIFF(HOUR, v_created_at, NOW());
  
  RETURN v_uptime_hours;
END//

DELIMITER ;

-- ============================================================================
-- SCHEDULED EVENTS (MySQL Event Scheduler)
-- ============================================================================

-- Enable event scheduler
SET GLOBAL event_scheduler = ON;

-- Event: Daily cleanup at 2 AM
CREATE EVENT IF NOT EXISTS evt_daily_cleanup
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 2 HOUR)
DO
  CALL cleanup_old_data();

-- Event: Monthly savings computation on 1st of month at 1 AM
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
  
  -- Get previous month
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
END;

-- Event: Archive old switch events quarterly
CREATE EVENT IF NOT EXISTS evt_quarterly_archive
ON SCHEDULE EVERY 3 MONTH
STARTS (DATE_ADD(DATE_ADD(LAST_DAY(CURRENT_DATE), INTERVAL 1 DAY), INTERVAL 3 HOUR))
DO
  CALL archive_switch_events(180); -- Keep 180 days in main table

-- ============================================================================
-- PERFORMANCE OPTIMIZATION QUERIES
-- ============================================================================

-- Analyze tables for query optimization
ANALYZE TABLE clients, agents, instances, spot_pools, spot_price_snapshots, 
             ondemand_price_snapshots, risk_scores, switch_events, 
             client_savings_monthly, system_events, pending_switch_commands;

-- ============================================================================
-- USEFUL OPERATIONAL QUERIES
-- ============================================================================

-- Query: Find agents that haven't heartbeated in 10 minutes
-- SELECT a.id, a.client_id, a.hostname, a.last_heartbeat, 
--        TIMESTAMPDIFF(MINUTE, a.last_heartbeat, NOW()) as minutes_since_heartbeat
-- FROM agents a
-- WHERE a.status = 'online' 
--   AND a.last_heartbeat < DATE_SUB(NOW(), INTERVAL 10 MINUTE);

-- Query: Find instances with high risk scores
-- SELECT i.id, i.instance_type, i.current_mode, i.current_pool_id,
--        rs.risk_score, rs.recommended_action, rs.reason
-- FROM instances i
-- JOIN risk_scores rs ON rs.instance_id = i.id
-- WHERE i.is_active = TRUE
--   AND rs.created_at = (
--     SELECT MAX(created_at) FROM risk_scores WHERE instance_id = i.id
--   )
--   AND rs.risk_score >= 0.7
-- ORDER BY rs.risk_score DESC;

-- Query: Calculate total potential savings
-- SELECT 
--   SUM((i.ondemand_price - COALESCE(i.spot_price, 0)) * 24 * 30) as potential_monthly_savings
-- FROM instances i
-- WHERE i.is_active = TRUE
--   AND i.current_mode = 'spot';

-- Query: Switch frequency by agent
-- SELECT 
--   a.id as agent_id,
--   a.hostname,
--   COUNT(se.id) as total_switches,
--   COUNT(CASE WHEN se.timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY) THEN 1 END) as switches_last_week,
--   AVG(se.savings_impact) as avg_savings_per_switch,
--   SUM(se.savings_impact) as total_savings_impact
-- FROM agents a
-- LEFT JOIN switch_events se ON se.agent_id = a.id
-- WHERE a.status = 'online'
-- GROUP BY a.id, a.hostname
-- ORDER BY total_switches DESC;

-- Query: Instance switch history with time between switches
-- SELECT 
--   instance_id,
--   timestamp,
--   from_mode,
--   to_mode,
--   savings_impact,
--   TIMESTAMPDIFF(HOUR, 
--     LAG(timestamp) OVER (PARTITION BY instance_id ORDER BY timestamp),
--     timestamp
--   ) as hours_since_last_switch
-- FROM switch_events
-- WHERE instance_id = 'i-12345abc'
-- ORDER BY timestamp DESC;

-- ============================================================================
-- MAINTENANCE COMMANDS
-- ============================================================================

-- Clean up old price snapshots (run periodically)
-- DELETE FROM spot_price_snapshots WHERE captured_at < DATE_SUB(NOW(), INTERVAL 30 DAY);
-- DELETE FROM ondemand_price_snapshots WHERE captured_at < DATE_SUB(NOW(), INTERVAL 30 DAY);

-- Clean up old risk scores (run periodically)
-- DELETE FROM risk_scores WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY);

-- Clean up executed pending commands older than 7 days
-- DELETE FROM pending_switch_commands WHERE executed_at < DATE_SUB(NOW(), INTERVAL 7 DAY);

-- Optimize tables after large deletions
-- OPTIMIZE TABLE spot_price_snapshots, ondemand_price_snapshots, risk_scores;

-- ============================================================================
-- GRANTS AND USERS
-- ============================================================================

-- Create application user with limited privileges
-- CREATE USER IF NOT EXISTS 'spot_optimizer_app'@'%' IDENTIFIED BY 'CHANGE_THIS_PASSWORD';
-- GRANT SELECT, INSERT, UPDATE, DELETE ON spot_optimizer.* TO 'spot_optimizer_app'@'%';
-- GRANT EXECUTE ON spot_optimizer.* TO 'spot_optimizer_app'@'%';

-- Create read-only user for analytics
-- CREATE USER IF NOT EXISTS 'spot_optimizer_readonly'@'%' IDENTIFIED BY 'CHANGE_THIS_PASSWORD';
-- GRANT SELECT ON spot_optimizer.* TO 'spot_optimizer_readonly'@'%';

-- Create admin user for maintenance
-- CREATE USER IF NOT EXISTS 'spot_optimizer_admin'@'%' IDENTIFIED BY 'CHANGE_THIS_PASSWORD';
-- GRANT ALL PRIVILEGES ON spot_optimizer.* TO 'spot_optimizer_admin'@'%';

-- FLUSH PRIVILEGES;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Verify schema
SELECT 
  TABLE_NAME, 
  TABLE_ROWS, 
  AUTO_INCREMENT, 
  CREATE_TIME,
  ROUND(((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024), 2) AS 'Size (MB)'
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'spot_optimizer'
ORDER BY TABLE_NAME;

-- Verify indexes
SELECT 
  TABLE_NAME,
  INDEX_NAME,
  GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) as COLUMNS,
  INDEX_TYPE,
  NON_UNIQUE
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'spot_optimizer'
GROUP BY TABLE_NAME, INDEX_NAME, INDEX_TYPE, NON_UNIQUE
ORDER BY TABLE_NAME, INDEX_NAME;

-- Verify sample data counts
SELECT 'Clients' as entity, COUNT(*) as count FROM clients
UNION ALL SELECT 'Agents', COUNT(*) FROM agents
UNION ALL SELECT 'Agent Configs', COUNT(*) FROM agent_configs
UNION ALL SELECT 'Instances', COUNT(*) FROM instances
UNION ALL SELECT 'Spot Pools', COUNT(*) FROM spot_pools
UNION ALL SELECT 'Spot Price Snapshots', COUNT(*) FROM spot_price_snapshots
UNION ALL SELECT 'On-Demand Price Snapshots', COUNT(*) FROM ondemand_price_snapshots
UNION ALL SELECT 'Risk Scores', COUNT(*) FROM risk_scores
UNION ALL SELECT 'Switch Events', COUNT(*) FROM switch_events
UNION ALL SELECT 'Monthly Savings', COUNT(*) FROM client_savings_monthly
UNION ALL SELECT 'System Events', COUNT(*) FROM system_events
UNION ALL SELECT 'Pending Commands', COUNT(*) FROM pending_switch_commands;

-- Verify views
SELECT TABLE_NAME, VIEW_DEFINITION
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA = 'spot_optimizer';

-- Verify stored procedures
SELECT ROUTINE_NAME, ROUTINE_TYPE, CREATED, LAST_ALTERED
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = 'spot_optimizer'
ORDER BY ROUTINE_TYPE, ROUTINE_NAME;

-- Verify triggers
SELECT TRIGGER_NAME, EVENT_MANIPULATION, EVENT_OBJECT_TABLE, ACTION_TIMING
FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = 'spot_optimizer'
ORDER BY EVENT_OBJECT_TABLE, TRIGGER_NAME;

-- Verify events
SELECT EVENT_NAME, STATUS, EVENT_TYPE, INTERVAL_VALUE, INTERVAL_FIELD, STARTS
FROM information_schema.EVENTS
WHERE EVENT_SCHEMA = 'spot_optimizer';

-- ============================================================================
-- QUICK START GUIDE
-- ============================================================================

/*
QUICK START:

1. Create database:
   mysql -u root -p < schema-fixed.sql

2. Verify installation:
   mysql -u spot_optimizer_app -p spot_optimizer
   
3. Test stored procedures:
   CALL calculate_monthly_savings('client-001', 2025, 11);
   CALL cleanup_old_data();
   CALL get_agent_statistics('agent-1a');

4. Check scheduled events:
   SHOW EVENTS;
   
5. Monitor active connections:
   SHOW PROCESSLIST;

6. View recent activity:
   SELECT * FROM v_recent_switches LIMIT 10;
   SELECT * FROM v_client_summary;

MAINTENANCE SCHEDULE:
- Daily 2 AM: Automatic cleanup (evt_daily_cleanup)
- Monthly 1st at 1 AM: Savings computation (evt_monthly_savings_computation)
- Quarterly: Archive old events (evt_quarterly_archive)

COMMON OPERATIONS:
- Add new client: INSERT INTO clients (id, name, client_token) VALUES (...);
- View agent status: SELECT * FROM v_client_summary;
- Check pending switches: SELECT * FROM pending_switch_commands WHERE executed_at IS NULL;
- Force cleanup: CALL cleanup_old_data();

*/

-- ============================================================================
-- SCHEMA COMPLETE - Version 1.1.0
-- ============================================================================