#!/bin/bash
# nagios(/etc/xinetd.d/nrpe)中配置postgres用户调用此脚本

export PGHOME=/opt/pgsql
export LANG=en_US.utf8
export LD_LIBRARY_PATH=$PGHOME/lib:/lib64:/usr/lib64:/usr/local/lib64:/lib:/usr/lib:/usr/local/lib:$LD_LIBRARY_PATH
export DATE=`date +"%Y%m%d%H%M"`
export PATH=$PGHOME/bin:$PATH:.

# FILE需和 sky_pg_clusterd.sh 里面配置的NAGIOS_FILE1 一致.
# ALIVE_MINUTES=1 表示1分钟内$FILE被修改过, 心跳存在. 否则心跳停止(告警).
# 文件对应sky_pg_cluster.sh中的NAGIOS_LOG
FILE=/tmp/sky_pg_clusterd.log
ALIVE_MINUTES=1
EXIST=1
ALIVE_CNT=0

if [ -f $FILE ]; then
  ALIVE_CNT=`find $FILE -mmin -$ALIVE_MINUTES -print|wc -l`
  if [ $ALIVE_CNT -eq 1 ]; then
    exit 0
  else
    echo -e "keepalive timeout $ALIVE_MINUTES mintues."
    exit 2
  fi
else
  echo -e "`date +%F%T` file $FILE not exists. "
  exit 2
fi

exit 1

# Author : Digoal zhou
# Email : digoal@126.com
# Blog : http://blog.163.com/digoal@126/
