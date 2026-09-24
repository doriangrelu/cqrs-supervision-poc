# syntax=docker/dockerfile:1
# Image d'un service du monorepo : docker build --build-arg MODULE=order-service -t poc/order-service .
#
# - build Maven dans l'image (reproductible, sans JDK sur le poste), cache ~/.m2 entre builds ;
# - jar Spring Boot éclaté en couches : dépendances (rarement modifiées) séparées du code (souvent modifié),
#   pour des pulls et pushes incrémentaux ;
# - exécution en utilisateur non root, mémoire JVM proportionnelle à la limite du conteneur.

FROM maven:3.9-eclipse-temurin-25 AS build
ARG MODULE
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/root/.m2 \
    mvn -q -B -pl "${MODULE}" -am package -DskipTests \
 && java -Djarmode=tools -jar "${MODULE}/target/${MODULE}-0.0.1-SNAPSHOT.jar" \
        extract --layers --launcher --destination /extracted

FROM eclipse-temurin:25-jre
RUN useradd --system --uid 10001 --no-create-home app
WORKDIR /app
COPY --from=build /extracted/dependencies/ ./
COPY --from=build /extracted/spring-boot-loader/ ./
COPY --from=build /extracted/snapshot-dependencies/ ./
COPY --from=build /extracted/application/ ./
USER 10001
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
