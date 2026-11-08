if [ -f /etc/my.cnf ] && cmp -s /etc/defaults/etc/my.cnf /etc/my.cnf
then
    rm /etc/my.cnf
fi

if [ -f /etc/my.cnf.d/client.cnf ] && cmp -s /etc/defaults/etc/my.cnf.d/client.cnf /etc/my.cnf.d/client.cnf
then
    rm /etc/my.cnf.d/client.cnf
fi

