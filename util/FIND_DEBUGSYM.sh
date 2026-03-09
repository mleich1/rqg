# Check if for all <whatever>/bin/mariadbd <whatever>/bin/mysqld
# the debugsym packages are installed
#
# Ubuntu
# ------
# sudo apt install debian-goodies
#
set -x
rm -rf dbgsym.tmp dbgsym.lst
for MARIADBD in `locate "bin/mariadbd" | grep "\/bin\/mariadbd$"`
do
    find-dbgsym-packages "$MARIADBD" >> dbgsym.tmp
done
for MYSQLD in `locate "bin/mysqld" | grep "\/bin\/mysqld$"`
do
    find-dbgsym-packages "$MYSQLD" >> dbgsym.tmp
done
sort -u dbgsym.tmp > dbgsym.lst

