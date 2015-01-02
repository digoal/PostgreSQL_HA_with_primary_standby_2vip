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

虚拟IP和角色的关系固定, 不会变化, 例如192.168.111.130对应primary角色, 那么不管怎么切换, 他们始终在一起(谁是primary, 谁就会启动192.168.111.130).

http://blog.163.com/digoal@126
