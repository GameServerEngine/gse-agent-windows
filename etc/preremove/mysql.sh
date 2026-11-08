if [ -f /etc/my.cnf.d/mysql-clients.cnf ] && cmp -s /etc/defaults/etc/my.cnf.d/mysql-clients.cnf /etc/my.cnf.d/mysql-clients.cnf
then
    rm /etc/my.cnf.d/mysql-clients.cnf
fi

if [ -f /etc/my.cnf.d/server.cnf ] && cmp -s /etc/defaults/etc/my.cnf.d/server.cnf /etc/my.cnf.d/server.cnf
then
    rm /etc/my.cnf.d/server.cnf
fi

