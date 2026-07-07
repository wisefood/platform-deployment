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
    CATALOG: 8000,
    CHROMA: 8000,
    NEO4J: 7474,
    NEO4J_BOLT: 7687,
    ELASTIC: 9200,
    API: 8000,
    UI: 80,
    FOODSCHOLAR: 8001,
    RECIPEWRANGLER: 8001,
    FOODCHAT: 8000,
    APISIX: 9080
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
    KC_FOODSCHOLAR_CLIENT_ID: "foodscholar",
    KC_RECIPEWRANGLER_CLIENT_ID: "recipewrangler",
    KC_FOODCHAT_CLIENT_ID: "foodchat",
    KC_MINIO_CLIENT_ID: "minio",
    KC_HOSTNAME_BACKCHANNEL_DYNAMIC: "true",
  },

  kafka: {
    KAFKA_BROKER_1_URL: "kafka-cluster:19092",
    KAFKA_BROKER_2_URL: "kafka-cluster:29092",
  },

  catalog: { 
    ES_DIM: '384',
    MINIO_BUCKET: 'catalog',
  },
  
  api: {
    MINIO_BUCKET: 'system',
  },

  ###########################
  ## GUEST ACCESS  ##########
  ###########################
  # Ephemeral guest accounts minted by wisefood-api (realm role 'guest').
  # TTL_SECONDS bounds a guest's lifetime; the API's reaper deletes the
  # Keycloak user, household and chat sessions after expiry.
  guest: {
    ENABLED: true,
    TTL_SECONDS: 24 * 3600,
    MAX_ACTIVE: 200,
  },

  ###########################
  ## LANGFUSE  ##############
  ###########################
  langfuse: {
    LANGFUSE_BASE_URL: "http://langfuse-web.langfuse.svc.cluster.local:3000",
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
    // Dedicated database for the FoodChat session store (owned by the wisefood user)
    FOODCHAT_DB: 'foodchat',
    KEYCLOAK_USER: 'keycloak',
    KEYCLOAK_SCHEMA: 'keycloak',
  },
}