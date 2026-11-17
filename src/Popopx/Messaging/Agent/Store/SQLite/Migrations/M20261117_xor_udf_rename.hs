{-# LANGUAGE QuasiQuotes #-}

module Popopx.Messaging.Agent.Store.SQLite.Migrations.M20261117_xor_udf_rename where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

-- The UDF is registered under both spellings (Agent/Store/SQLite.hs) until every database
-- has been through here: SQLite resolves a trigger's functions when the statement is
-- prepared, so an rcv_queues write fails outright while a trigger names an unregistered one
-- - including m20261008_rcv_switch_status, which runs before this migration does.
m20261117_xor_udf_rename :: Query
m20261117_xor_udf_rename =
  [sql|
DROP TRIGGER tr_rcv_queue_insert;
DROP TRIGGER tr_rcv_queue_delete;
DROP TRIGGER tr_rcv_queue_update_remove;
DROP TRIGGER tr_rcv_queue_update_add;

CREATE TRIGGER tr_rcv_queue_insert
AFTER INSERT ON rcv_queues
FOR EACH ROW
WHEN NEW.rcv_service_assoc != 0 AND NEW.deleted = 0
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count + 1,
      service_queue_ids_hash = popopx_xor_md5_combine(service_queue_ids_hash, NEW.rcv_id)
  WHERE user_id = (SELECT user_id FROM connections WHERE conn_id = NEW.conn_id)
    AND host = NEW.host AND port = NEW.port;
END;

CREATE TRIGGER tr_rcv_queue_delete
AFTER DELETE ON rcv_queues
FOR EACH ROW
WHEN OLD.rcv_service_assoc != 0 AND OLD.deleted = 0
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count - 1,
      service_queue_ids_hash = popopx_xor_md5_combine(service_queue_ids_hash, OLD.rcv_id)
  WHERE user_id = (SELECT user_id FROM connections WHERE conn_id = OLD.conn_id)
    AND host = OLD.host AND port = OLD.port;
END;

CREATE TRIGGER tr_rcv_queue_update_remove
AFTER UPDATE ON rcv_queues
FOR EACH ROW
WHEN OLD.rcv_service_assoc != 0 AND OLD.deleted = 0 AND NOT (NEW.rcv_service_assoc != 0 AND NEW.deleted = 0)
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count - 1,
      service_queue_ids_hash = popopx_xor_md5_combine(service_queue_ids_hash, OLD.rcv_id)
  WHERE user_id = (SELECT user_id FROM connections WHERE conn_id = OLD.conn_id)
    AND host = OLD.host AND port = OLD.port;
END;

CREATE TRIGGER tr_rcv_queue_update_add
AFTER UPDATE ON rcv_queues
FOR EACH ROW
WHEN NEW.rcv_service_assoc != 0 AND NEW.deleted = 0 AND NOT (OLD.rcv_service_assoc != 0 AND OLD.deleted = 0)
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count + 1,
      service_queue_ids_hash = popopx_xor_md5_combine(service_queue_ids_hash, NEW.rcv_id)
  WHERE user_id = (SELECT user_id FROM connections WHERE conn_id = NEW.conn_id)
    AND host = NEW.host AND port = NEW.port;
END;
|]

-- Restores the previous trigger text. Both spellings are registered, so the downgrade does
-- not have to run before the rename; the schema dump only moves on these four statements.
down_m20261117_xor_udf_rename :: Query
down_m20261117_xor_udf_rename =
  [sql|
DROP TRIGGER tr_rcv_queue_insert;
DROP TRIGGER tr_rcv_queue_delete;
DROP TRIGGER tr_rcv_queue_update_remove;
DROP TRIGGER tr_rcv_queue_update_add;

CREATE TRIGGER tr_rcv_queue_insert
AFTER INSERT ON rcv_queues
FOR EACH ROW
WHEN NEW.rcv_service_assoc != 0 AND NEW.deleted = 0
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count + 1,
      service_queue_ids_hash = simplex_xor_md5_combine(service_queue_ids_hash, NEW.rcv_id)
  WHERE user_id = (SELECT user_id FROM connections WHERE conn_id = NEW.conn_id)
    AND host = NEW.host AND port = NEW.port;
END;

CREATE TRIGGER tr_rcv_queue_delete
AFTER DELETE ON rcv_queues
FOR EACH ROW
WHEN OLD.rcv_service_assoc != 0 AND OLD.deleted = 0
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count - 1,
      service_queue_ids_hash = simplex_xor_md5_combine(service_queue_ids_hash, OLD.rcv_id)
  WHERE user_id = (SELECT user_id FROM connections WHERE conn_id = OLD.conn_id)
    AND host = OLD.host AND port = OLD.port;
END;

CREATE TRIGGER tr_rcv_queue_update_remove
AFTER UPDATE ON rcv_queues
FOR EACH ROW
WHEN OLD.rcv_service_assoc != 0 AND OLD.deleted = 0 AND NOT (NEW.rcv_service_assoc != 0 AND NEW.deleted = 0)
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count - 1,
      service_queue_ids_hash = simplex_xor_md5_combine(service_queue_ids_hash, OLD.rcv_id)
  WHERE user_id = (SELECT user_id FROM connections WHERE conn_id = OLD.conn_id)
    AND host = OLD.host AND port = OLD.port;
END;

CREATE TRIGGER tr_rcv_queue_update_add
AFTER UPDATE ON rcv_queues
FOR EACH ROW
WHEN NEW.rcv_service_assoc != 0 AND NEW.deleted = 0 AND NOT (OLD.rcv_service_assoc != 0 AND OLD.deleted = 0)
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count + 1,
      service_queue_ids_hash = simplex_xor_md5_combine(service_queue_ids_hash, NEW.rcv_id)
  WHERE user_id = (SELECT user_id FROM connections WHERE conn_id = NEW.conn_id)
    AND host = NEW.host AND port = NEW.port;
END;
|]
