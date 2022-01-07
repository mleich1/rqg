# Use in special cases only.
# Some thinkable *_connect_add would work better but *_connect_add is not yet supported.
thread_init_add:
    SET foreign_key_checks = 0, unique_checks = 0 ;
query_init_add:
    thread_init_add ;
