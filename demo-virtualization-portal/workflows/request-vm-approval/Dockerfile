FROM registry.redhat.io/openshift-serverless-1/logic-swf-builder-rhel8:1.36.0 AS builder

COPY src/main/resources/ /home/kogito/serverless-workflow-project/src/main/resources/

WORKDIR /home/kogito/serverless-workflow-project
RUN mvn package -B -ntp \
    -DskipTests \
    -Dquarkus.package.jar.type=mutable-jar

FROM registry.redhat.io/ubi8/openjdk-17-runtime:latest

COPY --from=builder /home/kogito/serverless-workflow-project/target/quarkus-app /deployments/

ENV JAVA_APP_JAR="/deployments/quarkus-run.jar"
ENV JAVA_OPTS="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"

EXPOSE 8080
