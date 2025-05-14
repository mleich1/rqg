# Warning:
# Up till today only RQG runs started via rqg_batch.pl work well with this grammar.
# Reason: RQG.sh and similar run in some not that fitting working directory.

thread1_init_add:
    { $other_log_dir = '"' . $ENV{PWD} . '/tmp"' ; mkdir $other_log_dir; return undef };

thread1_add:
    _random_log_change ;

_random_log_change:
    SET GLOBAL _random_log_op                                                 |
    SET GLOBAL _random_log_op, _random_log_op                                 |
    SET GLOBAL _random_log_op, _random_log_op, _random_log_op                 |
    SET GLOBAL _random_log_op, _random_log_op, _random_log_op, _random_log_op ;
_random_log_op:
    _ilfs |
    _ilg  |
    _ilfd |
    _ilcn ;
_ilfs:
    innodb_log_file_size =  50331648 |
    innodb_log_file_size = 100663296 |
    innodb_log_file_size = 201326592 ;
_ilg:
    innodb_log_group_home_dir = '/tmp' |
    innodb_log_group_home_dir = './'   ;
_ilfd:
    innodb_log_file_disabled = ON   |
    innodb_log_file_disabled = OFF  ;
_ilcn:
    innodb_log_checkpoint_now=ON  |
    innodb_log_checkpoint_now=OFF ;

