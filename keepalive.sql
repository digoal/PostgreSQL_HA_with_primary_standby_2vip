-- 建议使用superuser, 原因见http://blog.163.com/digoal@126/blog/static/163877040201331995623214/
create role sky_pg_cluster superuser nocreatedb nocreaterole noinherit login encrypted password 'SKY_PG_cluster_321';
create database sky_pg_cluster with template template0 encoding 'UTF8' owner sky_pg_cluster;
\c sky_pg_cluster sky_pg_cluster
create schema sky_pg_cluster authorization sky_pg_cluster;
create table cluster_status (id int unique default 1, last_alive timestamp(0) without time zone, rep_lag int8);

-- 限制cluster_status表有且只有一行 : 
CREATE FUNCTION cannt_delete ()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
   RAISE EXCEPTION 'You can not delete!';
END; $$;

CREATE TRIGGER cannt_delete
BEFORE DELETE ON cluster_status
FOR EACH ROW EXECUTE PROCEDURE cannt_delete();

CREATE TRIGGER cannt_truncate
BEFORE TRUNCATE ON cluster_status
FOR STATEMENT EXECUTE PROCEDURE cannt_delete();

-- 插入初始数据
insert into cluster_status values (1, now(), 9999999999);

-- 创建测试函数, 用于测试数据库是否正常, 包括所有表空间的测试
-- (注意原来的函数使用alter table set tablespace来做测试, 产生了较多的xlog, 同时需要排他锁, 现在改成update).
-- 使用update不同的表空间中的数据, 并不能立刻反应表空间的问题. 因为大多数数据在shared_buffer中.
-- 如果表空间对应的文件系统io有问题, 那么在checkpoint时会产生58类的错误.
-- 使用pg_stat_file函数可以立刻暴露io的问题.
create or replace function cluster_keepalive_test(i_peer_ip inet) returns void as $$
declare
  v_spcname text;
  v_spcoid oid;
  v_nspname name := 'sky_pg_cluster';
  v_rep_lag int8;
  v_t timestamp without time zone;
begin
  if ( pg_is_in_recovery() ) then
      raise notice 'this is standby node.';
      return;
  end if;
  select pg_xlog_location_diff(pg_current_xlog_insert_location(),sent_location) into v_rep_lag from pg_stat_replication where client_addr=i_peer_ip;
  if found then
    -- standby 已启动
    update cluster_status set last_alive=now(), rep_lag=v_rep_lag;
  else
    -- standby 未启动
    update cluster_status set last_alive=now();
  end if;

  -- 临时禁止检测表空间, return
  return;

  -- 表空间相关心跳检测1分钟一次, 减轻更新压力
  FOR v_spcname,v_spcoid IN 
    select spcname,oid from pg_tablespace where spcname <> 'pg_global' 
  LOOP
    perform 1 from pg_class where 
      ( reltablespace=v_spcoid or reltablespace=0 )
      and relname='t_'||v_spcname 
      and relkind='r' 
      and relnamespace=(select oid from pg_namespace where nspname=v_nspname)
      limit 1;
    if not found then
      execute 'create table '||v_nspname||'.t_'||v_spcname||' (crt_time timestamp) tablespace '||v_spcname;
      execute 'insert into '||v_nspname||'.t_'||v_spcname||' values ('''||now()||''')';
      perform pg_stat_file(pg_relation_filepath(v_nspname||'.t_'||v_spcname));
    else
      execute 'update '||v_nspname||'.t_'||v_spcname||' set crt_time='||''''||now()||''' where now()-crt_time> interval ''1 min'' returning crt_time' into v_t;
      if v_t is not null then
	perform pg_stat_file(pg_relation_filepath(v_nspname||'.t_'||v_spcname));
      end if;
    end if;
  END LOOP;
end;
$$ language plpgsql strict;
-- 在创建测试函数后, 最好测试一下是否正常, 因为某些版本的系统表可能不通用, 需要调整.
-- 9.2和9.3是没有问题的.



# Author : Digoal zhou
# Email : digoal@126.com
# Blog : http://blog.163.com/digoal@126/
