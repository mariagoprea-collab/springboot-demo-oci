FROM eclipse-temurin:17-jdk-jammy
WORKDIR /demo
COPY target/spring-boot-demo-eci.jar app.jar
RUN echo new test to see updated image
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
