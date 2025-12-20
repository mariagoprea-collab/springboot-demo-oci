FROM eclipse-temurin:17-jdk-jammy
WORKDIR /demo
COPY target/spring-boot-demo-eci.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
