PostgreSQL_HA_with_primary_standby_2vip
=======================================

A HA script for PostgreSQL with 2 HOST (one for primary, one for standby), Primary with one VIP, Standby with another VIP. Auto failover and failback.

两台主机, 分别负责primary和standby;

2个虚拟IP, 分别对应primary和standby;

三种状态, primary, standby, primary_standby;

三种状态自由切换:

  当1台主机异常时, 另一台主机承担primary_standby角色, 并启动2个虚拟IP.

  正常情况下两台主机分别承担primary和standby角色, 分别启动一个虚拟IP.

  应用程序连接虚拟IP, 其中一个虚拟IP对应的是primary, 另一个虚拟IP对应的是standby. 
  
  虚拟IP和角色的关系固定, 不会变化, 例如192.168.111.130对应primary角色, 那么不管怎么切换, 他们始终在一起(谁是primary,谁就会启动192.168.111.130).
  
  部署视频参考:
  
  http://www.tudou.com/programs/view/bIbZ85SrsHM/
  
  http://www.tudou.com/programs/view/kdRPT6dSp_0/
  
  http://www.tudou.com/programs/view/I6bxk2u3xdY/

=======================================

数据库角色转变和心跳原理 : 

1. 根据文件recovery.conf是否存在检测本地节点角色

    存在(standby), 不存在(master)

2. 加载NFS对端归档目录

3. 启动数据库
    如果是standby
      启动数据库
    如果是master
      如果其他主机未启动VIPM, 启动数据库

4. 启动VIP
    如果是standby
      启动vips
    如果是master
      如果vipm已被其他节点启动
        降级为standby
        启动vips
      如果vipm没有被其他节点启动
        启动vipm

5. 触发第一次心跳

6. 循环心跳检测

=======================================

不同的角色, 循环逻辑不同:

=======================================
master角色, 循环检查

  1. 网关检查, 反映本地网络状况

  2. 本地心跳检查, 反映本地数据库健康状态

  3. 本地角色对应IP检查

  4. 检查VIPS,PORT,数据库心跳

     如果本地健康,对端不健康

  触发切换

    1. 主节点fence standby

    2. 主节点接管VIPS

    3. 主节点转换master_standby角色

=======================================
standby角色, 循环检查

  1. 网关检查, 反映本地网络状况

  2. 本地心跳检查, 反映本地数据库健康状态

  3. 本地角色对应IP检查

  4. 检查备延迟, 判断是否允许promote

  5. 检查VIPM,PORT,数据库心跳

  如果本地健康,对端不健康

  触发切换

    1. 备节点fence master

    2. 备节点停库

    3. 备节点注释restore_command

    4. 备节点启动数据库

    5. 备节点激活数据库, 修改restore_command

    6. 备节点接管VIPM

    7. 备节点转换master_standby角色

=======================================
master_standby角色, 循环检查

  1. 检查对端数据库心跳

  如果对端数据库心跳正常

    触发释放vips

    1. 释放vips

    2. 转换为master角色

图片

架构
![架构](https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip/raw/master/m_s_ha_1.png)
![架构](https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip/raw/master/m_s_ha_arch.png)

主角
![主角](https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip/raw/master/m_s_ha_2.png)

备角
![备角](https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip/raw/master/m_s_ha_3.png)

主备合一角
![主备合一](https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip/raw/master/m_s_ha_4.png)

逻辑
![逻辑1](https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip/blob/master/m_s_1.png)
![逻辑2](https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip/blob/master/m_s_2.png)
![逻辑3](https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip/blob/master/m_s_3.png)
![逻辑4](https://github.com/digoal/PostgreSQL_HA_with_primary_standby_2vip/blob/master/m_s_4.png)

# Author : Digoal zhou
# Email : digoal@126.com
# Blog : http://blog.163.com/digoal@126/
