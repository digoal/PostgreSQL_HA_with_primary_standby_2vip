#!/bin/bash

# 需要调试时, 取消set -x注释
# set -x

. /etc/profile
. /home/postgres/.bash_profile

# 配置, node1,node2 可能不一致, psql, pg_ctl等命令必须包含在PATH中.
export PGHOME=/opt/pgsql
export LANG=en_US.utf8
export LD_LIBRARY_PATH=$PGHOME/lib:/lib64:/usr/lib64:/usr/local/lib64:/lib:/usr/lib:/usr/local/lib:$LD_LIBRARY_PATH
export DATE=`date +"%Y%m%d%H%M"`
export PATH=$PGHOME/bin:/bin:/sbin:$PATH:.
export PGDATA=/opt/pg_root

# 配置, node1,node2 可能不一致, 
# 并且需配置.pgpass存储VIPM, VIPS, LOCAL 心跳用户 密码校验信息.
# 存储VIPM 流复制用户 密码校验信息
# 网关IP, 用于arping检测本地网络是否正常, 如果没有网关, 使用一个广播域内的第三方IP也可行.
VIP_IF=eth0
VIPM_IF=eth0:1
VIPS_IF=eth0:2
VIPM_IP=192.168.111.130
VIPS_IP=192.168.111.131
GATEWAY_IP=192.168.111.1

# 配置, node1,node2 不一致, 配置(对方)节点的物理IP, 以及fence设备地址和用户密码
PEER_IP=192.168.111.42
FENCE_IP=192.168.112.51
FENCE_USER=digoal
FENCE_PWD="digoal_pwd"

# 数据库心跳用户, 库名配置
PGUSER=sky_pg_cluster
PGDBNAME=sky_pg_cluster

# 本地心跳连接配置
LOCAL_IP=127.0.0.1
PGPORT=1921

# 归档和PEER归档目录, 注意规定postgresql.conf -> archive_command归档命令使用ARCH/$DATA/这样的格式
LOCAL_ARCH_DIR="/opt/arch"
PEER_ARCH_DIR="/opt/peer_arch"

# 日志输出
NAGIOS_LOG="/tmp/sky_pg_clusterd.log"

# 脚本名, 用于停止脚本, 必须与脚本名一致
SUB_NAME="$(basename $BASH_SOURCE)"

# sudo 命令绝对路径
S_IFUP="`which ifup`"
S_IFDOWN="`which ifdown`"
S_ARPING="`which arping`"
S_MOUNT="`which mount`"
S_UMOUNT="`which umount`"

# 依赖命令
DEP_CMD="sudo ifup ifdown arping mount umount port_probe pg_ctl psql ipmitool"

# 9.0 使用触发器文件
# TRIG_FILE='/data01/pgdata/pg_root/.1921.trigger'

# 检测所有需要用到的命令是否存在
which $DEP_CMD 
if [ $? -ne 0 ]; then
  echo -e "dep commands: $DEP_CMD not exist."
  exit 1
fi

# 检测当前角色, 通过recovery.xx检查, 记录到变量
if [ -f $PGDATA/recovery.conf ]; then
  LOCAL_ROLE="standby"
else
  LOCAL_ROLE="master"
fi
echo "this is $LOCAL_ROLE"


# 函数

# 检测IP是否已被其他主机启动, 返回0表示IP已启动.
# 同时通过判断网关ARP返回, 可以用于判断本地网络是否正常.
ipscan() {
  ETH=$1
  IP=$2
  echo "`date +%F%T` detecting $ETH $IP exists, ps: return 0 exist, other not exist."
  CN=`sudo $S_ARPING -b -c 5 -w 1 -f -I $ETH $IP|grep response|awk '{print $2}'`
  if [ $CN -eq 1 ]; then
    return 0
  else
    return 1
  fi
}

# 启动虚拟IP, 返回0 成功
ifup_vip() {
  # 无限启动vip
  IF=$1
  for ((m=1;m>0;m=1))
  do
    echo -e "`date +%F%T` $IF if upping. $m."
    sudo $S_IFUP $IF
    if [ $? -eq 0 ]; then
      echo -e "`date +%F%T` $IF upped success."
      break
    fi
    sleep 1
  done
  return 0
}

# 通过BMC接口关闭主机
# 返回0成功, 其他不成功
fence() {
  # 无限fence, 加参数 force, 加其他参数不强制fence
  # ipmitool -I lanplus -L OPERATOR -H $IP -U $USER -P $PWD power reset
  # fence_rsa -a $IP -l $USER -p $PWD -o reboot
  # fence_ilo -a $IP -l $USER -p $PWD -o reboot
  IP=$1
  USER=$2
  PWD=$3
  F_METHOD=$4
  EXCMD="fence_ilo -a $IP -l $USER -p $PWD -o reboot"
  if [ $F_METHOD == "force" ]; then
    echo "`date +%F%T` force fenceing, waiting..."
    for ((m=1;m>0;m++))
    do
      $EXCMD
      if [ $? -eq 0 ]; then
        break
      else
        sleep 1
      fi
    done
  else
    echo "`date +%F%T` normal fenceing, waiting..."
    $EXCMD
    # 返回fence成功与否
    return $?
  fi
  return 0
}


# 将备数据库激活为主库
promote() {
  # 停库
  pg_ctl stop -m fast -w -t 60000

  # 备份pg_root, 不包含表空间(建议表空间 不要 建立在$PGDATA目录下, 否则这里会非常巨大)
  mv $LOCAL_ARCH_DIR/pg_root.s $LOCAL_ARCH_DIR/pg_root.s.`date +%F%T`
  cp -rP $PGDATA $LOCAL_ARCH_DIR/pg_root.s
  chmod -R 755 $LOCAL_ARCH_DIR/pg_root.s
  
  # 修改recovery.conf, 注释restore_command
  sed -i -e 's/^restore_command/#digoal_restore_command/' $PGDATA/recovery.conf
  # 启动数据库
  pg_ctl start -w -t 60000
  
  # 开始 promote
  echo "`date +%F%T` promoting database ..."
  pg_ctl promote
  # PostgreSQL 9.0 不能使用pg_ctl promote
  # touch $TRIG_FILE
  
  # 等待激活成功后返回
  SQL="set client_min_messages=warning; select 'this_is_primary' as res where not pg_is_in_recovery();"
  for ((m=1;m>0;m++))
  do
    echo "`date +%F%T` testing promote status"
    LAG=`echo $SQL | psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - | grep -c this_is_primary`
    if [ $LAG -eq 1 ]; then
      echo "`date +%F%T` promote success."
      # 还原修改recovery.done, 取消注释restore_command
      sed -i -e 's/^#digoal_restore_command/restore_command/' $PGDATA/recovery.done
      
      # 创建检查点, 切换xlog
      psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -c "checkpoint"
      psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -c "select pg_switch_xlog()"
      psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -c "checkpoint"
      psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -c "select pg_switch_xlog()"
      psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -c "checkpoint"
      return 0
    else
      echo "`date +%F%T` promoting..."
      sleep 1
    fi
  done
}

# 主库降级成备库
degrade() {
  DATE=`date +%F%T`
  
  # 停库,备份控制文件,拷贝对端控制文件,重命名recovery.done,启动数据库
  echo "`date +%F%T` degrading database ..."
  pg_ctl stop -m fast -w -t 60000
  
  # 备份pg_root, 不包含表空间(建议表空间 不要 建立在$PGDATA目录下, 否则这里会非常巨大)
  cp -rP $PGDATA $LOCAL_ARCH_DIR/pg_root.m.$DATE
  
  # 拷贝对端pg_root, 覆盖当前pg_root
  rm -rf $PGDATA/*
  cp -rP $PEER_ARCH_DIR/pg_root.s/* $PGDATA/
  chmod -R 700 $PGDATA/*

  pg_ctl start -w -t 60000
  # 返回数据库是否启动成功
  return $?
}


# 备节点延迟判断, 0表示允许激活, 其他表示不允许激活
# 第一个参数时间秒, 第二个参数字节数
enable_promote() {
  SEC=$1
  BYTE=$2
  echo "`date +%F%T` detecting standby enable promote for lag testing..."
  SQL="set client_min_messages=warning; select 'standby_in_allowed_lag' as cluster_lag from cluster_status where now()-last_alive < interval '$SEC second' and rep_lag<=$BYTE;"
  # 连接到本地数据库查询延迟
  LAG=`echo $SQL | psql -h $LOCAL_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -f - | grep -c standby_in_allowed_lag`
  if [ $LAG -eq 1 ]; then
    return 0
  fi
  return 1
}

# 心跳, 返回0正常, 其他不正常.
keepalive() {
  # 区分主库和本地IP, 调用心跳函数
  
  # 检查主节点时, 使用vipm_ip
  # 检查本地节点时, 使用local_ip
  DEST_IP=$1
  
  # 写入心跳数据
  SQL="select cluster_keepalive_test('$PEER_IP');"
  psql -h $DEST_IP -p $PGPORT -U $PGUSER -d $PGDBNAME -c "$SQL"
  return $?
}


# 检查主库状态, 返回0正常, 其他不正常
# 异常超过$1秒返回异常
checkmaster() {
  TIMEOUT=$1
  echo "`date +%F%T` $FUNCNAME."
  for ((m=1;m>0;m++))
  do
    sleep 1
    echo "$FUNCNAME check times: $m"
    # 检测vipm是否正常
    ipscan $VIP_IF $VIPM_IP
    RET=$?
    # 超时返回
    if [ $m -ge $TIMEOUT ] && [ $RET -ne 0 ]; then
      echo "$FUNCNAME ipscan timeout: $TIMEOUT"
      return 1
    # 网络异常, 但是未超时继续检测
    elif [ $RET -ne 0 ]; then
      continue
    fi

    # 检查数据库监听
    port_probe $VIPM_IP $PGPORT
    RET=$?
    if [ $m -ge $TIMEOUT ] && [ $RET -ne 0 ]; then
      echo "$FUNCNAME port_probe timeout: $TIMEOUT"
      return 1
    # 数据库监听异常, 但是未超时继续检测
    elif [ $RET -ne 0 ]; then
      continue
    fi

    # 检查主数据库心跳
    keepalive $VIPM_IP
    RET=$?
    if [ $m -ge $TIMEOUT ] && [ $RET -ne 0 ]; then
      echo "$FUNCNAME keepalive timeout: $TIMEOUT"
      return 1
    # 数据库心跳异常, 但是未超时继续检测
    elif [ $RET -ne 0 ]; then
      continue
    fi
    
    # 全部正常, 退出循环
    break
  done

  # 全部正常, 返回0
  return 0
}

# 检查备库状态, 返回0正常, 其他不正常
# 异常超过$1秒返回异常
checkstandby() {
  TIMEOUT=$1
  echo "`date +%F%T` $FUNCNAME."
  for ((m=1;m>0;m++))
  do
    sleep 1
    echo "$FUNCNAME check times: $m"
    
    # 检测vips是否正常
    ipscan $VIP_IF $VIPS_IP
    RET=$?
    # VIPS异常, 同时超时, 返回异常
    if [ $m -ge $TIMEOUT ] && [ $RET -ne 0 ]; then
      echo "$FUNCNAME ipscan timeout: $TIMEOUT"
      return 1
    # VIPS异常, 但是未超时, 继续检测
    elif [ $RET -ne 0 ]; then
      continue
    fi

    # 检查数据库监听
    port_probe $VIPS_IP $PGPORT
    RET=$?
    # 数据库监听异常, 同时超时, 返回异常
    if [ $m -ge $TIMEOUT ] && [ $RET -ne 0 ]; then
      echo "$FUNCNAME port_probe timeout: $TIMEOUT"
      return 1
    # 数据库监听异常, 但是未超时, 继续检测
    elif [ $RET -ne 0 ]; then
      continue
    fi

    # 检查备库心跳, keepalive务必支持standby 模式.
    keepalive $VIPS_IP
    RET=$?
    if [ $m -ge $TIMEOUT ] && [ $RET -ne 0 ]; then
      echo "$FUNCNAME keepalive timeout: $TIMEOUT"
      return 1
    # 数据库心跳异常, 但是未超时继续检测
    elif [ $RET -ne 0 ]; then
      continue
    fi

    # 全部正常, 退出循环
    break
  done

  # 全部正常, 返回0
  return 0
}

# 本地IP地址检查, 检查IP是否启动, 返回0表示已启动
# 用于检查子接口地址是否启动
ipaddrscan() {
  S_IF=$1
  S_IP=$2
  echo "`date +%F%T` detecting $S_IP address up on $S_IF ...."
  CNT=`ip addr show dev $S_IF|grep -c "${S_IP}/"`
  if [ $CNT -eq 1 ]; then
    return 0
  fi
  return 1
}



start() {
# 初始化.............................................................................
# 根据角色, 进入初始化流程

keepalive $VIPM_IP
if [ $? -ne 0 ]; then
  # 避免standby激活的时间超过服务器启动时间, 设置一个初始化延迟
  echo "`date +%F%T` sleep, waiting other host promoting..."
  sleep 45
fi

# 加载peer归档文件
# 如果对端节点未启动, 会卡在这里
sudo $S_MOUNT -t nfs -o tcp $PEER_IP:$LOCAL_ARCH_DIR $PEER_ARCH_DIR

echo "`date +%F%T` this is $LOCAL_ROLE"

if [ $LOCAL_ROLE == "standby" ]; then
  # 判断数据库是否已启动
  port_probe $LOCAL_IP $PGPORT
  if [ $? -ne 0 ]; then
    # 启动数据库
    pg_ctl start -w -t 60000
    if [ $? -ne 0 ]; then
      # 数据库启动不成功, 退出脚本
      echo "startup standby db failed."
      exit 1
    fi
  else
    echo "database is already startup."
  fi
fi

if [ $LOCAL_ROLE == "master" ]; then
  # 判断数据库是否已启动
  port_probe $LOCAL_IP $PGPORT
  if [ $? -ne 0 ]; then
    # -> 启动数据库
    pg_ctl start -w -t 60000
    if [ $? -ne 0 ]; then
      # 数据库启动不成功, 退出脚本
      echo "startup master db failed."
      exit 1
    fi
  else
    echo "database is already startup."
  fi
fi


# 初始化启动vip
# local_role=standby
# if vips up -> (等待, ifup vips) -> end if
# if vips down -> ifup vips -> end if

# if vipm down -> 每秒检测vipm状况 
#                -> if wait<600s && vipm down 继续检测
#              -> if wait>=600s && vipm down -> fence 对方 -> ifup vipm, vips -> promote -> 本地角色更新为master+standby
#              -> if wait<600s && vipm up -> 退出循环

if [ $LOCAL_ROLE == "standby" ]; then
  # 无限启动vips
  for ((m=1;m>0;m=1))
  do
    # 判断vips是否已被其他主机启动
    ipscan $VIP_IF $VIPS_IP
    RET=$?
    # 如果vips未启动, 启动vips, 并退出循环
    if [ $RET -ne 0 ]; then
      echo "`date +%F%T` if upping vips."
      ifup_vip $VIPS_IF
      break
    else
      # 无限循环, 等待其他主机vips释放
      echo "`date +%F%T` waiting vips released by other host."
      sleep 1
    fi
  done
fi

# local_role=master -> 
# if vipm down -> ifup vipm
# if vips down -> ifup vips -> 本地角色更新为master+standby
# if vipm up -> copy ctl from 对方 -> mv recovery.done to recover.conf -> mv pg_xlog to old_pg_xlog -> restart db -> (循环ifup vips) -> 本地角色更新为standby

if [ $LOCAL_ROLE == "master" ]; then
  # 无限启动vipm
  # 判断vipm是否已被其他主机启动
  ipscan $VIP_IF $VIPM_IP
  RET=$?
  # 如果vipm未启动
  if [ $RET -ne 0 ]; then
    echo "`date +%F%T` if upping vipm."
    ifup_vip $VIPM_IF
    # 判断vips是否已启动, 未启动则启动, 并将角色转换为m_s
    ipscan $VIP_IF $VIPS_IP
    RET=$?
    if [ $RET -ne 0 ]; then
      echo "`date +%F%T` if upping vips. change to m_s role."
      ifup_vip $VIPS_IF
      LOCAL_ROLE="m_s"
    fi
  # 如果vipm已启动, 转换成standby, 启动vips, 更新角色
  else
    echo "`date +%F%T` degrading to standby, ifup vips, change to standby role."
    degrade
    ifup_vip $VIPS_IF
    LOCAL_ROLE="standby"
  fi
fi


# 触发一次心跳, 更新数据以备测试enable_promote
# 不需要关心结果
keepalive $VIPM_IP


# 循环
# local_role=master
# 检测vips -> fence -> ifup vips -> 本地角色更新为master+standby
# local_role=standby
# 检测vipm -> fence -> ifup vipm -> 本地角色更新为master+standby
# local_role=master+standby
# 检测对方IP -> 等待20s -> 释放vips -> 等待对方启动vips -> 本地角色更新为master

# 无限循环, 
# (切换前提: 心跳检测), 
# (本地状态: 本地网络监测, 本地心跳检测, 本地角色对应IP检测), 
# (日志, 邮件, nagios告警), 
# 角色自由切换
for ((m=1;m>0;m=1))
do
  echo "`date +%F%T` this is $LOCAL_ROLE"
  sleep 1

  # m_s和standby,master不一样的地方, 不需要依赖本地健康状态, 务必在必要时释放vips.
  if [ $LOCAL_ROLE == "m_s" ]; then
    # 如果本地不健康, 写日志, 邮件, nagios告警 
    # 网关检查, 反映本地网络状况, 不影响释放vips, 只做日志输出
    ipscan $VIP_IF $GATEWAY_IP
    if [ $? -ne 0 ]; then
      echo "`date +%F%T` can not connect to gateway."
    fi

    # 本地心跳检查, 反映本地数据库健康状态, 不影响释放vips, 只做日志输出
    keepalive $LOCAL_IP
    if [ $? -ne 0 ]; then
      echo "`date +%F%T` local database not health."
    fi

    # 本地角色对应IP检查, 不影响释放vips, 只做日志输出
    ipaddrscan $VIP_IF $VIPM_IP
    if [ $? -ne 0 ]; then
      echo "`date +%F%T` vipm not up."
    fi
    ipaddrscan $VIP_IF $VIPS_IP
    if [ $? -ne 0 ]; then
      echo "`date +%F%T` vips not up."
    fi

    # 检测对端IP数据库心跳是否已健康, 如果健康, 释放vips
    echo "`date +%F%T` detecting peer postgresql keepalive."
    keepalive $PEER_IP
    if [ $? -eq 0 ]; then
      # 释放vips
      echo "`date +%F%T` release vips."
      sudo $S_IFDOWN $VIPS_IF

      # 等待对方完成degrade, 300秒, 转换为master
      echo "`date +%F%T` sleeping 120 second."
      sleep 300
      # 转变角色
      LOCAL_ROLE="master"
    fi
  fi

  # standby, master角色, 本地状态检查
  # 如果本地不健康, 写日志, 邮件, nagios告警, continue不进行后续peer节点检查.
  # 通常需人工处理本地状态异常.

  # 网关检查, 反映本地网络状况
  ipscan $VIP_IF $GATEWAY_IP
  if [ $? -ne 0 ]; then
    echo "`date +%F%T` can not connect to gateway."
    continue
  fi

  # 本地心跳检查, 反映本地数据库健康状态
  keepalive $LOCAL_IP
  if [ $? -ne 0 ]; then
    echo "`date +%F%T` local database not health."
    continue
  fi

  if [ $LOCAL_ROLE == "standby" ]; then    
    # 如果本地不健康, 写日志, 邮件, nagios告警, continue不进行后续检查.
    # 本地角色对应IP检查
    ipaddrscan $VIP_IF $VIPS_IP
    if [ $? -ne 0 ]; then
      echo "`date +%F%T` vips not up."
      continue
    fi

    # 检查主备延迟, 判断是否适合激活数据库
    # 假设延迟判断, 600秒以及16MB
    # 注意这个延迟时间必须大于checkmaster的超时时间.
    enable_promote 600 16000000
    if [ $? -ne 0 ]; then
      echo "`date +%F%T` can not promote."
      # 可能是对端正在等待造成, 主动发起心跳, 不管结果
      keepalive $VIPM_IP
      continue
    fi
    
    # 异常超过5次, 触发切换, 角色转变
    checkmaster 5
    if [ $? -ne 0 ]; then
      fence $FENCE_IP $FENCE_USER $FENCE_PWD force
      RET=$?
      # fence成功, 备份旧控制文件到指定目录, 激活, 启动vipm, 并转换角色.
      if [ $RET -eq 0 ]; then
        promote
        ifup_vip $VIPM_IF
        LOCAL_ROLE="m_s"
      else
        # fence不成功, 可能是fence设备网络异常或fence配置有问题, 则继续探测, 不转换角色.
        echo "fence master failed, continue checkmaster."
        continue
      fi
    else
      # 检查正常, continue
      echo "check master normal."
      continue
    fi
  fi
  
  if [ $LOCAL_ROLE == "master" ]; then
    # 如果本地不健康, 写日志, 邮件, nagios告警, continue不进行后续检查.
    # 本地角色对应IP检查
    ipaddrscan $VIP_IF $VIPM_IP
    if [ $? -ne 0 ]; then
      echo "`date +%F%T` vipm not up."
      continue
    fi
    
    # 异常超过5次, 触发切换, 角色转变
    checkstandby 5
    if [ $? -ne 0 ]; then
      # 这里不使用强制fence
      fence $FENCE_IP $FENCE_USER $FENCE_PWD normal
      RET=$?
      # fence 成功
      if [ $RET -eq 0 ]; then
        ifup_vip $VIPS_IF
        LOCAL_ROLE="m_s"
      else
        # fence不成功, 可能是fence设备网络异常或fence配置有问题, 则继续探测, 不转换角色.
        echo "`date +%F%T` fence standby failed."
        continue
      fi
    fi
  fi
  
done
}

# 停止本脚本, 数据库, 释放子IP, 释放peer归档目录
stopall() {
  pg_ctl stop -m fast
  sudo $S_IFDOWN $VIPS_IF
  sudo $S_IFDOWN $VIPM_IF
  sudo $S_UMOUNT -l $PEER_ARCH_DIR
  # 自杀
  killall $SUB_NAME
}

# 停止本脚本
stopscript() {
  killall $SUB_NAME
}

# 停止数据库
stopdb() {
  pg_ctl stop -m fast
}

# 状态
status() {
  tail -n 30 $NAGIOS_LOG
  ps -ewf|grep $SUB_NAME
}

# See how we are called
case "$1" in
        start)
                start >>$NAGIOS_LOG 2>&1 &
                RETVAL=$?
                ;;
        stop)
                stopall
                RETVAL=$?
                ;;
        status)
                status
                ;;
        restart)
                stopall
                start >>$NAGIOS_LOG 2>&1 &
                RETVAL=$?
                ;;
        *)
                echo $"Usage: $0 {start|stop|status|restart}"
                RETVAL=3
                ;;
esac

exit $RETVAL


# Author : Digoal zhou
# Email : digoal@126.com
# Blog : http://blog.163.com/digoal@126/
