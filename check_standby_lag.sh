#!/bin/bash
# nagios(/etc/xinetd.d/nrpe)中配置postgres用户调用此脚本
export PGHOME=/opt/pgsql
export LANG=en_US.utf8
export LD_LIBRARY_PATH=$PGHOME/lib:/lib64:/usr/lib64:/usr/local/lib64:/lib:/usr/lib:/usr/local/lib:$LD_LIBRARY_PATH
export DATE=`date +"%Y%m%d%H%M"`
export PATH=$PGHOME/bin:$PATH:.

# 配置, node1,node2 可能不一致, 并且需配置.pgpass存储以下密码校验信息
# LAG_MINUTES=3 表示3分钟. 延时超过3分钟则告警.
LOCAL_IP=127.0.0.1
PGUSER=sky_pg_cluster
PGPORT=1921
PGDBNAME=sky_pg_cluster
LAG_MINUTES=3
SQL1="set client_min_messages=warning; select 'standby_in_allowed_lag' as cluster_lag from cluster_status where now()-last_alive < interval '$LAG_MINUTES min';"

# standby lag 在接受范围内的标记, LAG=1 表示正常.
LAG=`echo $SQL1 | psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - | grep -c standby_in_allowed_lag`
if [ $LAG -eq 1 ]; then
  exit 0
else
  echo -e "standby is laged far $LAG_MINUTES mintues from primary . "
  exit 1
fi

exit 1

# Author : Digoal zhou
# Email : digoal@126.com
# Blog : http://blog.163.com/digoal@126/
