FROM ubi8

RUN yum install -y httpd
RUN echo '<h1>Hello from Red Hat!</h1>' > /var/www/html/index.html

CMD ["/usr/sbin/httpd", "-D", "FOREGROUND"]
