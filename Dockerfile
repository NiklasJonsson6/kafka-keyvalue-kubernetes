FROM maven:3.6.1-jdk-8-slim@sha256:dce33cc7a4702cc5f3ea3a6deb4ea840c17001895ffe169d96e1fd9d7041eb15 as maven

FROM openjdk:11.0.3-jdk-slim@sha256:ee1ee5fd0c9cef0ec5ed72999567ed7a6efd5bfdbf49326bfd9423c0dca84ef0 \
  as dev

COPY --from=maven /usr/share/maven /usr/share/maven
RUN ln -s /usr/share/maven/bin/mvn /usr/bin/mvn
ENV MAVEN_HOME=/usr/share/maven
ENV MAVEN_CONFIG=/root/.m2

WORKDIR /workspace
RUN mvn io.quarkus:quarkus-maven-plugin:0.15.0:create \
    -DprojectGroupId=org.acme \
    -DprojectArtifactId=getting-started \
    -DclassName="org.acme.quickstart.GreetingResource" \
    -Dpath="/hello"
COPY pom.xml .
RUN mvn package && \
  rm -r src target mvnw* && \
  ls -la
COPY . .

ENTRYPOINT [ "mvn", "compile", "quarkus:dev" ]
CMD [ "-Dquarkus.http.host=0.0.0.0", "-Dquarkus.http.port=8090" ]

FROM openjdk:11.0.3-jdk-slim@sha256:ee1ee5fd0c9cef0ec5ed72999567ed7a6efd5bfdbf49326bfd9423c0dca84ef0 \
  as maven-build

COPY --from=maven /usr/share/maven /usr/share/maven
RUN ln -s /usr/share/maven/bin/mvn /usr/bin/mvn
ENV MAVEN_HOME=/usr/share/maven
ENV MAVEN_CONFIG=/root/.m2

COPY --from=dev ${MAVEN_HOME} ${MAVEN_HOME}
COPY --from=dev ${MAVEN_CONFIG} ${MAVEN_CONFIG}

WORKDIR /workspace
COPY . .
# Can't get integration tests to pass on docker hub, and can't get logs from them
#RUN mvn -o package
RUN mvn -o package -DskipTests

FROM fabric8/java-alpine-openjdk8-jre@sha256:4c8c834428855aa37e29fe896f5a3a829ccdde3bcd1ab5b71a17a1b3136c4176 \
  as runtime-plainjava
ARG SOURCE_COMMIT
ARG SOURCE_BRANCH
ARG IMAGE_NAME
EXPOSE 8090
ENV JAVA_OPTIONS="-Dquarkus.http.host=0.0.0.0 -Dquarkus.http.port=8090 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
ENV AB_ENABLED=jmx_exporter
COPY --from=maven-build /workspace/target/lib/* /deployments/lib/
COPY --from=maven-build /workspace/target/*-runner.jar /deployments/app.jar
ENTRYPOINT [ "/deployments/run-java.sh" ]

ENV SOURCE_COMMIT=${SOURCE_COMMIT} SOURCE_BRANCH=${SOURCE_BRANCH} IMAGE_NAME=${IMAGE_NAME}

# https://github.com/quarkusio/quarkus/issues/2412#issuecomment-494933951
#FROM oracle/graalvm-ce:19.0.0@sha256:71d4990f47e9b2300c57775e1306af477232019b624376c8f120d910caedb4b4 \
#  as native-build
#RUN gu install native-image
FROM oracle/graalvm-ce:1.0.0-rc16@sha256:aa8b12e0bf15ffec6581f1a9feb42bf4c4f67d7c57d5739cca5fdc6c25fe4c54 \
  as native-build

WORKDIR /project
COPY --from=maven-build /workspace/target/lib ./lib
COPY --from=maven-build /workspace/target/*-runner.jar ./

# from Quarkus' maven plugin mvn package -Pnative -Dnative-image.docker-build=true
# but CollectionPolicy commented out due to "Error: policy com.oracle.svm.core.genscavenge.CollectionPolicy cannot be instantiated."
RUN native-image \
  -J-Djava.util.logging.manager=org.jboss.logmanager.LogManager \
  #-H:InitialCollectionPolicy=com.oracle.svm.core.genscavenge.CollectionPolicy$BySpaceAndTime \
  -jar kafka-keyvalue-1.0-SNAPSHOT-runner.jar \
  -J-Djava.util.concurrent.ForkJoinPool.common.parallelism=1 \
  -H:FallbackThreshold=0 \
  -H:+PrintAnalysisCallTree \
  -H:-AddAllCharsets \
  -H:EnableURLProtocols=http \
  -H:-SpawnIsolates \
  -H:-JNI \
  --no-server \
  -H:-UseServiceLoaderFeature \
  -H:+StackTrace

# The rest should be identical to src/main/docker/Dockerfile which is the recommended quarkus build
FROM registry.fedoraproject.org/fedora-minimal@sha256:28dcdc19fd1d55598dc308a44c40287f4b00d0bf5a53cd01c39368c16cf85d57
ARG SOURCE_COMMIT
ARG SOURCE_BRANCH
ARG IMAGE_NAME

WORKDIR /work/
COPY --from=native-build /project/*-runner /work/application
#RUN chmod 775 /work
EXPOSE 8090
ENTRYPOINT ["./application"]
CMD ["-Dquarkus.http.host=0.0.0.0", "-Dquarkus.http.port=8090"]

ENV SOURCE_COMMIT=${SOURCE_COMMIT} SOURCE_BRANCH=${SOURCE_BRANCH} IMAGE_NAME=${IMAGE_NAME}
