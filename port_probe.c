/*                                                                                                                                  
# 用于探测仲裁服务器上的vip端口代理.                                                                                                
# install:                                                                                                                          
# gcc -O3 -Wall -Wextra -Werror -g -o port_probe ./port_probe.c                                                                     
                                                                                                                                    
# Author : Digoal zhou                                                                                                              
# Email : digoal@126.com                                                                                                            
# Blog : http://blog.163.com/digoal@126/                                                                                            
*/


#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <strings.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/time.h>


// 错误函数, 当exit_val=0只输出错误信息, 不退出程序. 其他值输出错误信息并退出程序
void error(char * msg, int exit_val);

void error(char * msg, int exit_val) {
  fprintf(stderr, "%s: %s\n", msg, strerror(errno));
  // if exit_val == 0, not exit the program.
  if (exit_val)
    exit(exit_val);
}

int main(int argc,char *argv[])
{
  if(argc == 1)
    error("USAGE [program ip port]", 1);
  int cfd;
  struct sockaddr_in s_add;
     
  cfd = socket(AF_INET, SOCK_STREAM, 0);
  if(-1 == cfd)
    error("socket create failed!", -1);
  fprintf(stdout, "socket created!\n");

  bzero(&s_add, sizeof(struct sockaddr_in));
  s_add.sin_family=AF_INET;
  s_add.sin_addr.s_addr= inet_addr(argv[1]);
  s_add.sin_port=htons(atoi(argv[2]));

  // 设置连接超时, 否则如果端口不通, connect可能会很久.
  struct timeval tv_timeout;
  tv_timeout.tv_sec = 2;
  tv_timeout.tv_usec = 0;

  // 避免本地出现TIME_WAIT
  struct linger {
     int l_onoff; /* 0 = off, nozero = on */
     int l_linger; /* linger time */
  };
  struct linger so_linger;
  so_linger.l_onoff = 1;
  so_linger.l_linger = 0;

  if (setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, (void *) &tv_timeout, sizeof(struct timeval)) < 0) {
    error("setsockopt SO_SNDTIMEO error!", -1);
  }
  if (setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, (void *) &tv_timeout, sizeof(struct timeval)) < 0) {
    error("setsockopt SO_RCVTIMEO error!", -1);
  }
  if (setsockopt(cfd, SOL_SOCKET, SO_LINGER, (void *) &so_linger, sizeof(so_linger)) < 0) {
    error("setsockopt SO_LINGER error!", -1);
  }

  if(-1 == connect(cfd, (struct sockaddr *)(&s_add), sizeof(struct sockaddr))) {
    error("connect failed!", -1);
  }
  fprintf(stdout, "connect ok!\n");

  close(cfd);
  return 0;
}
