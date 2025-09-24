##########################################
## The Platform Independent Model ########
##########################################
# This structure contains parameters     #
# that wont change when deploying the    #
# cluster among different platforms.     #
##########################################


{
  ###########################
  ## TCP PORTS  #############
  ###########################
  ports: {
    REDIS: 6379,
    DATAPUSHER: 8800,
    DB: 5432,
    KEYCLOAK: 8080,
    MINIO:9001,
    MINIOAPI:9000,
    MONGO:27017,
  },
  

  ###########################
  ## KEYCLOAK  ##############
  ###########################
  keycloak: {
    DB_TYPE: 'postgres',
    KEYCLOAK_ADMIN: 'admin',
    JDBC_PARAMS: 'useSsl=false',
    KC_HTTP_ENABLED: "true",
    KC_HEALTH_ENABLED: "true",
    REALM: 'master',
    KC_WISEFOOD_PUBLIC_CLIENT_ID: "wisefood-ui",
    KC_WISEFOOD_PRIVATE_CLIENT_ID: "wisefood-api",
    KC_MINIO_CLIENT_ID: "minio",
    KC_HOSTNAME_BACKCHANNEL_DYNAMIC: "true",
  },

  kafka: {
    KAFKA_BROKER_1_URL: "kafka-cluster:19092",
    KAFKA_BROKER_2_URL: "kafka-cluster:29092",
  },
  
  ###########################
  ## DATABASE  ##############
  ###########################
  db: {
    POSTGRES_HOST: 'db',
    POSTGRES_PORT: 5432,
    POSTGRES_DEFAULT_DB: 'postgres',
    POSTGRES_USER: 'postgres',
    WISEFOOD_DB: 'wisefood',
    WISEFOOD_USER: 'wisefood',
    WISEFOOD_SCHEMA: 'wisefood',
    KEYCLOAK_USER: 'keycloak',
    KEYCLOAK_SCHEMA: 'keycloak',
  },
}