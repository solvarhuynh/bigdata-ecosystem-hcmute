FROM ubuntu:24.04

LABEL maintainer="BigData-N14 <nghia-master>"
ENV DEBIAN_FRONTEND=noninteractive

# 1. Cài đặt các gói phụ thuộc cần thiết: OpenJDK 8, OpenSSH, Python3, Pip, Rsync, Curl, Net-tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-8-jdk \
    openssh-server \
    openssh-client \
    rsync \
    curl \
    wget \
    tar \
    sudo \
    net-tools \
    iputils-ping \
    python3 \
    python3-pip \
    nano \
    && rm -rf /var/lib/apt/lists/*

# 2. Tạo user `hadoopnghia` và cấu hình quyền sudo không cần password
RUN useradd -m -s /bin/bash hadoopnghia && \
    usermod -aG sudo hadoopnghia && \
    echo "hadoopnghia ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# 3. Thiết lập SSH keys cho cả root và hadoopnghia (không password để tự do ssh liên node)
RUN mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh && \
    ssh-keygen -t rsa -P '' -f /root/.ssh/id_rsa && \
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys && \
    chmod 600 /root/.ssh/authorized_keys && \
    echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config && \
    echo "UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config

USER hadoopnghia
RUN mkdir -p /home/hadoopnghia/.ssh && \
    chmod 700 /home/hadoopnghia/.ssh && \
    ssh-keygen -t rsa -P '' -f /home/hadoopnghia/.ssh/id_rsa && \
    cat /home/hadoopnghia/.ssh/id_rsa.pub >> /home/hadoopnghia/.ssh/authorized_keys && \
    chmod 600 /home/hadoopnghia/.ssh/authorized_keys
USER root

# 4. Thiết lập biến môi trường phiên bản và đường dẫn
ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
ENV HADOOP_VERSION=3.4.0
ENV HIVE_VERSION=3.1.3
ENV SPARK_VERSION=3.5.1

ENV HADOOP_HOME=/opt/hadoop
ENV HIVE_HOME=/opt/hive
ENV SPARK_HOME=/opt/spark
ENV HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop
ENV PYSPARK_PYTHON=/usr/bin/python3
ENV PYSPARK_DRIVER_PYTHON=/usr/bin/python3

ENV PATH=$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HIVE_HOME/bin:$SPARK_HOME/bin:$SPARK_HOME/sbin

# 5. Tải và cài đặt Hadoop 3.4.0, Hive 3.1.3, Spark 3.5.1
WORKDIR /opt

RUN set -eux; \
    curl --fail --location --retry 5 --retry-all-errors --retry-delay 5 \
         --connect-timeout 30 --max-time 1800 --progress-bar \
         -o hadoop-${HADOOP_VERSION}.tar.gz \
         https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz; \
    tar -xzf hadoop-${HADOOP_VERSION}.tar.gz && \
    mv hadoop-${HADOOP_VERSION} hadoop && \
    rm hadoop-${HADOOP_VERSION}.tar.gz

RUN set -eux; \
    curl --fail --location --retry 5 --retry-all-errors --retry-delay 5 \
         --connect-timeout 30 --max-time 1800 --progress-bar \
         -o apache-hive-${HIVE_VERSION}-bin.tar.gz \
         https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz; \
    tar -xzf apache-hive-${HIVE_VERSION}-bin.tar.gz && \
    mv apache-hive-${HIVE_VERSION}-bin hive && \
    rm apache-hive-${HIVE_VERSION}-bin.tar.gz

RUN set -eux; \
    curl --fail --location --retry 5 --retry-all-errors --retry-delay 5 \
         --connect-timeout 30 --max-time 1800 --progress-bar \
         -o spark-${SPARK_VERSION}-bin-hadoop3.tgz \
         https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz; \
    tar -xzf spark-${SPARK_VERSION}-bin-hadoop3.tgz && \
    mv spark-${SPARK_VERSION}-bin-hadoop3 spark && \
    rm spark-${SPARK_VERSION}-bin-hadoop3.tgz

# FIX XUNG ĐỘT GUAVA GIỮA HIVE 3.1.3 VÀ HADOOP 3.4.X (Thay thế guava cũ của Hive bằng guava từ Hadoop)
RUN rm -f /opt/hive/lib/guava-*.jar && \
    cp /opt/hadoop/share/hadoop/common/lib/guava-*.jar /opt/hive/lib/

# 6. Tạo các thư mục data cần thiết và phân quyền cho hadoopnghia
RUN mkdir -p /opt/hadoop/hdfs/namenode \
             /opt/hadoop/hdfs/datanode \
             /opt/hadoop/tmp \
             /opt/hive/metastore_db \
             /var/run/sshd && \
    chown -R hadoopnghia:hadoopnghia /opt/hadoop /opt/hive /opt/spark /opt/hadoop/hdfs /opt/hadoop/tmp /opt/hive/metastore_db

# 7. Đồng bộ file cấu hình
COPY config/hadoop/* /opt/hadoop/etc/hadoop/
COPY config/hive/hive-site.xml /opt/hive/conf/
COPY config/spark/spark-defaults.conf /opt/spark/conf/
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 9870 9000 8088 8032 8030 8031 9083 10000 10002 7077 8080 22

ENTRYPOINT ["/entrypoint.sh"]
