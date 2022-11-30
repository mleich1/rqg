# MDEV-27812 Allow SET GLOBAL innodb_log_file_size (MariaDB 10.9)
# Essential:
# The change of the innodb_log_file_size happens immediate and not somehow
# delayed like during shutdown or on next server startup.

query_add:
    # By using the rule innodb_log_file_resize it happens a bit less frequent.
    innodb_log_file_resize ;

innodb_log_file_resize:
    # Range:
    # >= MariaDB 10.8.3: 4194304 to 512GB (4MB to 512GB)
    # innodb_log_file_size must be >= innodb_log_buffer_size.
    # The default for innodb_log_buffer_size is 16777216B.
    # Hence the first setting will most probably fail.
    SET GLOBAL innodb_log_file_size =   4194304 |
    SET GLOBAL innodb_log_file_size =  16777216 |
    SET GLOBAL innodb_log_file_size =  67108864 ;
