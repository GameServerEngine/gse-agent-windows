if [ -f /etc/pki/tls/openssl10.cnf ] && cmp -s /etc/defaults/etc/pki/tls/openssl10.cnf /etc/pki/tls/openssl10.cnf
then
    rm /etc/pki/tls/openssl10.cnf
fi

