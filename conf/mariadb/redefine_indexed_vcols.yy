# MDEV-39261: Crash in row_vers_build_clust_v_col during purge with indexed virtual columns
#
# Redefine grammar that creates tables with indexed virtual columns and performs
# heavy DML to stress the InnoDB purge thread's virtual column computation.
#
# The crash occurs in innobase_get_computed_value() called from
# row_vers_build_clust_v_col() during row_purge_is_unsafe() when the purge
# thread tries to compute virtual column values after backup restore / server restart.
#
# Compatible with MariabackupIncremental and other reporters that restart the server.
# Usage: --redefine=conf/mariadb/redefine_indexed_vcols.yy

query_init_add:
  ivc_init ; ivc_init ; ivc_init ; ivc_init ; ivc_init
;

query_add:
  ivc_action
;

ivc_init:
  CREATE OR REPLACE TABLE { $ivc_tbl = 'ivc_t'.$prng->int(1,10); $ivc_tbl } (
    id     BIGINT NOT NULL AUTO_INCREMENT,
    ref    BIGINT NOT NULL DEFAULT 0,
    status INT NOT NULL DEFAULT 1,
    gateway INT DEFAULT 0,
    flags  INT UNSIGNED DEFAULT 0,
    amount DECIMAL(14,2) DEFAULT 0.00,
    created TIMESTAMP NOT NULL DEFAULT '2000-01-01 00:00:00',
    modified TIMESTAMP NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
    payload BLOB DEFAULT NULL,
    vcol_flag_a  TINYINT(1) GENERATED ALWAYS AS (flags & 1 <> 0) VIRTUAL,
    vcol_flag_b  TINYINT(1) GENERATED ALWAYS AS (flags & 4 <> 0) VIRTUAL,
    vcol_flag_c  TINYINT(1) GENERATED ALWAYS AS (flags & 64 <> 0) VIRTUAL,
    vcol_flag_d  TINYINT(1) GENERATED ALWAYS AS (flags & 256 <> 0) VIRTUAL,
    vcol_flag_e  TINYINT(1) GENERATED ALWAYS AS (flags & 512 <> 0) VIRTUAL,
    vcol_flag_f  TINYINT(1) GENERATED ALWAYS AS (flags & 2147483648 <> 0) VIRTUAL,
    vcol_status_gw INT GENERATED ALWAYS AS (status + gateway) VIRTUAL,
    vcol_ref_mod BIGINT GENERATED ALWAYS AS (ref % 1000) VIRTUAL,
    PRIMARY KEY (id),
    KEY idx_status (status, gateway, flags),
    KEY idx_ref (ref),
    KEY idx_vcol_a (vcol_flag_a),
    KEY idx_vcol_b (vcol_flag_b),
    KEY idx_vcol_c (vcol_flag_c),
    KEY idx_vcol_de (vcol_flag_d, vcol_flag_e, status),
    KEY idx_vcol_e (vcol_flag_e),
    KEY idx_vcol_f (vcol_flag_f),
    KEY idx_vcol_sg (vcol_status_gw),
    KEY idx_vcol_rm (vcol_ref_mod)
  ) ENGINE=InnoDB
;

ivc_action:
  # === DML on dedicated ivc_t* tables (specific schema) ===
    ivc_insert | ivc_insert | ivc_insert | ivc_insert | ivc_insert
  | ivc_insert | ivc_insert | ivc_insert | ivc_insert | ivc_insert
  | ivc_update | ivc_update | ivc_update | ivc_update
  | ivc_delete | ivc_delete
  | ivc_replace
  | ivc_insert_select
  # DDL that interacts with virtual columns on ivc_t* tables
  | ivc_alter | ivc_alter
  # Re-create occasionally to vary schema
  | ivc_init
  # Queries that force reads through virtual column indexes
  | ivc_select | ivc_select
  # Transaction boundaries to vary commit/rollback timing for purge
  | ivc_transaction
  # === Generic rules operating on ANY table in the schema ===
  # Add/drop indexed virtual columns on existing tables
  | gen_ivc_add_vcol | gen_ivc_add_vcol | gen_ivc_add_vcol
  | gen_ivc_drop_vcol
  | gen_ivc_add_idx_on_vcol | gen_ivc_add_idx_on_vcol
  # Heavy DML on any table to generate undo records for purge
  | gen_ivc_heavy_dml | gen_ivc_heavy_dml | gen_ivc_heavy_dml | gen_ivc_heavy_dml
  | gen_ivc_heavy_dml | gen_ivc_heavy_dml | gen_ivc_heavy_dml | gen_ivc_heavy_dml
  # SELECT through virtual column expressions on any table
  | gen_ivc_select_vcol | gen_ivc_select_vcol
  # ALTER TABLE FORCE / ENGINE on any table (forces vcol template rebuild)
  | gen_ivc_alter
  # Cross-table INSERT...SELECT to mix undo across tables
  | gen_ivc_insert_select
  # TRUNCATE to create purge-heavy scenarios
  | gen_ivc_truncate
;

ivc_table_name:
    { $ivc_tbl = 'ivc_t'.$prng->int(1,10); $ivc_tbl }
;

ivc_insert:
  INSERT IGNORE INTO ivc_table_name (ref, status, gateway, flags, amount, payload)
    VALUES ( ivc_ref_val, ivc_status_val, ivc_gateway_val, ivc_flags_val, ivc_amount_val, ivc_payload_val ) ivc_extra_rows
;

ivc_extra_rows:
  |
  , ( ivc_ref_val, ivc_status_val, ivc_gateway_val, ivc_flags_val, ivc_amount_val, ivc_payload_val ) |
  , ( ivc_ref_val, ivc_status_val, ivc_gateway_val, ivc_flags_val, ivc_amount_val, ivc_payload_val )
  , ( ivc_ref_val, ivc_status_val, ivc_gateway_val, ivc_flags_val, ivc_amount_val, ivc_payload_val ) |
  , ( ivc_ref_val, ivc_status_val, ivc_gateway_val, ivc_flags_val, ivc_amount_val, ivc_payload_val )
  , ( ivc_ref_val, ivc_status_val, ivc_gateway_val, ivc_flags_val, ivc_amount_val, ivc_payload_val )
  , ( ivc_ref_val, ivc_status_val, ivc_gateway_val, ivc_flags_val, ivc_amount_val, ivc_payload_val )
  , ( ivc_ref_val, ivc_status_val, ivc_gateway_val, ivc_flags_val, ivc_amount_val, ivc_payload_val )
;

ivc_replace:
  REPLACE INTO ivc_table_name (id, ref, status, gateway, flags, amount)
    VALUES ( _mediumint_unsigned, ivc_ref_val, ivc_status_val, ivc_gateway_val, ivc_flags_val, ivc_amount_val )
;

ivc_insert_select:
    INSERT IGNORE INTO ivc_table_name (ref, status, gateway, flags, amount)
      SELECT ref, status, gateway, flags ^ ivc_flags_val , amount FROM ivc_table_name LIMIT _digit
  | INSERT IGNORE INTO ivc_table_name (ref, status, gateway, flags, amount)
      SELECT ref + _digit , status, gateway, flags | ivc_flags_val , amount FROM _table LIMIT _digit
;

ivc_update:
    UPDATE ivc_table_name SET flags  = ivc_flags_val   WHERE ivc_where_cond LIMIT _digit
  | UPDATE ivc_table_name SET status = ivc_status_val  WHERE ivc_where_cond LIMIT _digit
  | UPDATE ivc_table_name SET flags  = flags ^ ivc_flags_val WHERE ivc_where_cond LIMIT _digit
  | UPDATE ivc_table_name SET flags  = flags | ivc_flags_val , status = ivc_status_val WHERE ivc_where_cond LIMIT _digit
  | UPDATE ivc_table_name SET gateway = ivc_gateway_val, flags = flags & ~ivc_flags_val WHERE ivc_where_cond LIMIT _digit
  | UPDATE ivc_table_name SET ref = ref + 1, flags = ivc_flags_val WHERE ivc_where_cond LIMIT _digit
  | UPDATE ivc_table_name SET amount = ivc_amount_val, flags = flags | ivc_flags_val WHERE id = _mediumint_unsigned
;

ivc_delete:
    DELETE FROM ivc_table_name WHERE ivc_where_cond ORDER BY id LIMIT _digit
  | DELETE FROM ivc_table_name WHERE ivc_where_cond LIMIT _smallint_unsigned
  | DELETE FROM ivc_table_name ORDER BY id LIMIT _digit
;

ivc_select:
    SELECT * FROM ivc_table_name WHERE vcol_flag_a = ivc_bool_val AND vcol_flag_b = ivc_bool_val LIMIT 10
  | SELECT * FROM ivc_table_name FORCE INDEX (idx_vcol_de) WHERE vcol_flag_d = ivc_bool_val AND vcol_flag_e = ivc_bool_val LIMIT 10
  | SELECT vcol_status_gw, COUNT(*) FROM ivc_table_name GROUP BY vcol_status_gw LIMIT 10
  | SELECT * FROM ivc_table_name WHERE vcol_ref_mod = _digit LIMIT 10
  | SELECT id, flags, vcol_flag_a, vcol_flag_b, vcol_flag_c FROM ivc_table_name WHERE vcol_flag_f = 1 LIMIT 10
;

ivc_where_cond:
    vcol_flag_a = ivc_bool_val
  | vcol_flag_b = ivc_bool_val
  | vcol_flag_c = ivc_bool_val
  | vcol_flag_d = ivc_bool_val AND vcol_flag_e = ivc_bool_val
  | vcol_flag_f = ivc_bool_val
  | vcol_status_gw > _digit
  | vcol_ref_mod = _digit
  | status = ivc_status_val
  | id BETWEEN _mediumint_unsigned AND _mediumint_unsigned
  | flags & ivc_flags_val <> 0
;

# =============================================================================
# Generic rules operating on ANY table in the schema via _table, _field, etc.
# These add indexed virtual columns to existing base grammar tables and do
# heavy DML through them, maximizing purge thread stress on vcol computation.
# =============================================================================

# Add an indexed virtual column to any existing table.
# Uses _field_int as the source column so expression is valid for INT-like columns.
# IF NOT EXISTS prevents errors if column already exists.
gen_ivc_add_vcol:
    ALTER TABLE _table ADD COLUMN IF NOT EXISTS gen_ivc_vcol_name gen_ivc_vcol_expr , ADD KEY IF NOT EXISTS gen_ivc_idx_name ( { $last_column } )
  | ALTER TABLE _table ADD COLUMN IF NOT EXISTS gen_ivc_vcol_name gen_ivc_vcol_expr
;

# Virtual column expression types — derived from any existing INT column
gen_ivc_vcol_expr:
    TINYINT(1) GENERATED ALWAYS AS ( _field_int & gen_ivc_bitmask <> 0 ) VIRTUAL
  | TINYINT(1) GENERATED ALWAYS AS ( _field_int & gen_ivc_bitmask <> 0 ) VIRTUAL
  | TINYINT(1) GENERATED ALWAYS AS ( _field_int & gen_ivc_bitmask <> 0 ) VIRTUAL
  | INT GENERATED ALWAYS AS ( _field_int + _digit ) VIRTUAL
  | INT GENERATED ALWAYS AS ( _field_int * 2 + 1 ) VIRTUAL
  | BIGINT GENERATED ALWAYS AS ( _field_int % 1000 ) VIRTUAL
  | INT GENERATED ALWAYS AS ( ABS( _field_int ) ) VIRTUAL
  | INT GENERATED ALWAYS AS ( IFNULL( _field_int , 0 ) + _digit ) VIRTUAL
  | INT GENERATED ALWAYS AS ( _field_int DIV 10 ) VIRTUAL
  | INT GENERATED ALWAYS AS ( COALESCE( _field_int , 0 ) ) VIRTUAL
;

# Bitmask values matching MDEV-39261 pattern (powers of 2, combinations)
gen_ivc_bitmask:
    1 | 2 | 4 | 8 | 16 | 32 | 64 | 128 | 256 | 512 | 1024
  | 2048 | 4096 | 65536 | 2147483648
;

# Generated vcol column names — kept small pool so indexes hit existing vcols often
gen_ivc_vcol_name:
    { $last_column = 'gvc'.$prng->int(1,8); $last_column }
;

# Index names for generic virtual columns
gen_ivc_idx_name:
    gvc_idx1 | gvc_idx2 | gvc_idx3 | gvc_idx4 | gvc_idx5 | gvc_idx6 | gvc_idx7 | gvc_idx8
;

# Drop a previously added virtual column from any table
gen_ivc_drop_vcol:
    ALTER TABLE _table DROP COLUMN IF EXISTS gen_ivc_vcol_name
  | ALTER TABLE _table DROP KEY IF EXISTS gen_ivc_idx_name
;

# Add an index on an already-added virtual column on any table
gen_ivc_add_idx_on_vcol:
    ALTER TABLE _table ADD KEY IF NOT EXISTS gen_ivc_idx_name ( gen_ivc_vcol_name )
  | ALTER TABLE _table DROP KEY IF EXISTS gen_ivc_idx_name , ADD KEY gen_ivc_idx_name ( gen_ivc_vcol_name )
;

# Heavy DML on any table — generates undo records that purge must process
# while virtual column indexes exist on the table
gen_ivc_heavy_dml:
    INSERT INTO _table SELECT * FROM _table LIMIT _digit
  | INSERT INTO _table SELECT * FROM _table LIMIT _digit
  | INSERT IGNORE INTO _table SELECT * FROM _table LIMIT _smallint_unsigned
  | UPDATE _table SET _field_int = _digit WHERE _field_int = _digit LIMIT _digit
  | UPDATE _table SET _field_int = _field_int + 1 LIMIT _digit
  | UPDATE _table SET _field_int = _field_int | gen_ivc_bitmask LIMIT _digit
  | UPDATE _table SET _field_int = _field_int & ~gen_ivc_bitmask LIMIT _digit
  | UPDATE _table SET _field_int = _field_int ^ gen_ivc_bitmask LIMIT _digit
  | DELETE FROM _table LIMIT _digit
  | DELETE FROM _table WHERE _field_int > _digit LIMIT _digit
  | DELETE FROM _table ORDER BY _field_int LIMIT _smallint_unsigned
;

# SELECT through virtual column expressions on any table to force vcol reads
gen_ivc_select_vcol:
    SELECT * FROM _table WHERE _field_int & gen_ivc_bitmask <> 0 LIMIT 10
  | SELECT * FROM _table WHERE _field_int & gen_ivc_bitmask = 0 LIMIT 10
  | SELECT _field_int , _field_int & gen_ivc_bitmask AS vcflag FROM _table LIMIT 20
  | SELECT COUNT(*) FROM _table WHERE _field_int & gen_ivc_bitmask <> 0
  | SELECT _field_int + _digit AS computed FROM _table ORDER BY computed LIMIT 10
  | SELECT * FROM _table IGNORE INDEX (_field) WHERE _field_int > _digit LIMIT 10
;

# ALTER TABLE FORCE / ENGINE=InnoDB on any table — rebuilds the table,
# forces vc_templ reinitialization which is part of the MDEV-39261 crash path
gen_ivc_alter:
    ALTER TABLE _table FORCE
  | ALTER TABLE _table ENGINE=InnoDB
  | ALTER TABLE _table FORCE , ALGORITHM=COPY
  | ALTER TABLE _table FORCE , ALGORITHM=INPLACE
  | OPTIMIZE TABLE _table
;

# Cross-table INSERT...SELECT to generate mixed undo records
gen_ivc_insert_select:
    INSERT IGNORE INTO _table SELECT * FROM _table LIMIT _smallint_unsigned
  | INSERT IGNORE INTO _table ( _field_int ) SELECT _field_int FROM _table LIMIT _digit
;

# TRUNCATE creates massive purge work
gen_ivc_truncate:
    TRUNCATE TABLE _table
;

ivc_alter:
    ALTER TABLE ivc_table_name FORCE
  | ALTER TABLE ivc_table_name ENGINE=InnoDB
  | ALTER TABLE ivc_table_name DROP KEY IF EXISTS ivc_extra_idx_name , ADD KEY ivc_extra_idx_name ( ivc_vcol_name )
  | ALTER TABLE ivc_table_name ADD COLUMN IF NOT EXISTS ivc_new_vcol_def
  | ALTER TABLE ivc_table_name DROP COLUMN IF EXISTS ivc_new_vcol_name
;

ivc_extra_idx_name:
    idx_extra1 | idx_extra2 | idx_extra3
;

ivc_vcol_name:
    vcol_flag_a | vcol_flag_b | vcol_flag_c | vcol_flag_d | vcol_flag_e | vcol_flag_f
  | vcol_status_gw | vcol_ref_mod
;

ivc_new_vcol_name:
    { $ivc_newvcol = 'xvcol'.$prng->int(1,5); $ivc_newvcol }
;

ivc_new_vcol_def:
    ivc_new_vcol_name ivc_new_vcol_type
;

ivc_new_vcol_type:
    INT GENERATED ALWAYS AS (flags + status) VIRTUAL
  | TINYINT(1) GENERATED ALWAYS AS (flags & 1024 <> 0) VIRTUAL
  | BIGINT GENERATED ALWAYS AS (ref * status) VIRTUAL
  | INT GENERATED ALWAYS AS (gateway + status * 10) VIRTUAL
;

ivc_transaction:
    BEGIN | BEGIN
  | COMMIT | COMMIT | COMMIT
  | ROLLBACK
  | SAVEPOINT ivc_sp
  | ROLLBACK TO SAVEPOINT ivc_sp
;

ivc_sp:
  ivc_sp1 | ivc_sp2
;

# Value generators matching the real-world MDEV-39261 table pattern
ivc_ref_val:
  _mediumint_unsigned | _bigint_unsigned | _digit
;

ivc_status_val:
  0 | 1 | 2 | 3 | 4 | 5
;

ivc_gateway_val:
  0 | 1 | 2 | 3 | 10 | 20
;

# Flags matching the bitmask pattern from the MDEV-39261 table:
# 1, 4, 64, 256, 512, 2147483648
ivc_flags_val:
    0 | 1 | 4 | 5 | 64 | 65 | 68
  | 256 | 260 | 512 | 516 | 576 | 768 | 772
  | 2147483648 | 2147483649 | 2147483652 | 2147484160
  | { $prng->int(0, 4294967295) }
;

ivc_amount_val:
  0.00 | 1.50 | 99.99 | 1000.00 | _digit
;

ivc_payload_val:
  NULL | NULL | NULL | '' | _char(64) | REPEAT('x', 200)
;

ivc_bool_val:
  0 | 1
;
