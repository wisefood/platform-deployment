local tk_env = import 'spec.json';
local urllib = import "urllib.libsonnet";
local g = import 'generate.libsonnet';
local defaults = import 'pim.libsonnet';
local secrets = import 'secrets.libsonnet';

{
  _tk_env:: tk_env.spec,
  _config+:: {
    namespace: tk_env.spec.namespace,
    dynamicStorageClass: 'csi-hostpath-sc',
  },
  provisioning:: {
    namespace: $._config.namespace,
    dynamic_volume_storage_class: 'csi-hostpath-sc',
  },
  system:: {
    dns: {
      /*
      In order for the system to be able to operate,
      (2) subdomains (belonging to ROOT_DOMAIN) are needed:
      - KEYCLOAK: Keycloak SSO server needs a dedicated
                  domain in order to serve SSO to services.
                  We choose here to use subdomain which
                  will work just fine.
      - MINIO_API: In order to avoid conflicts with MinIO
                  paths (confusing a MinIO path for a
                  reverse proxy path) we choose to use
                  separate subdomain for the MinIO API only
                  (Note: MinIO CONSOLE is served by the
                  PRIMARY subdomain. )
      */
      SCHEME: "http",
      ROOT_DOMAIN: "minikube",
      KEYCLOAK_SUBDOMAIN: "auth",
      MINIO_SUBDOMAIN: "s3",
    },
    admin: {
      email: "dpetrou@athenarc.gr",
    },
  },
  configuration::
    self.system
    + {
      api: {
        SMTP_SERVER: "wisefood.gr",
        SMTP_PORT: "465",
        SMTP_USERNAME: "admin@wisefood.gr",
      }
    }
    + {
      secrets: {
        db: {
          postgres: "postgres-db-pass",
          system: "wisefood-db-pass",
          keycloak: "keycloak-db-pass",
        },
        keycloak: {
          sysadmin_pass: "sysadmin-pass",
          wisefood_api: "kc-wisefood-api-secret",
          minio: "kc-minio-client-secret",
        },
        api: {
          smtp_pass: "smtp-pass",
          session_secret: "session-secret",
        },
        minio: {
          minio_root: "sysadmin-pass",
        }
      }
    },
  ##########################################
  ## The Platform Independent Model ########
  ##########################################
  pim::
    self.provisioning
    + {
        images: {
          POSTGRES:"wisefood/postgres:latest",
          MINIO:"quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z-cpuv1",
          KEYCLOAK:"wisefood/keycloak:latest",
          KEYCLOAK_INIT:"wisefood/keycloak-init:latest",
          REDIS:"redis:7",
          CATALOG: "wisefood/data-catalog:latest",
          ELASTIC: "docker.elastic.co/elasticsearch/elasticsearch:8.14.3",
        },
    }
    + defaults,

  /*
  Here the library for each component is
  defined in order to use them for manifest
  generation later on. The services included
  here will be deployed in the K8s cluster.
  */
  components:: [
    import 'db.libsonnet',
    import 'redis.libsonnet',
    import 'elastic.libsonnet',
    import 'catalog.libsonnet',
    import 'keycloak.libsonnet',
    import 'minio.libsonnet',
    import 'ingress.libsonnet',
    import 'sysinit.libsonnet',
  ],
  /*
  Translate to manifests. This will call the
  manifest function of each component above,
  passing the PIM and Config as arguments. This
  will generate the manifests for all services.
  */
  manifests: g.generate_manifest($.pim, $.configuration, $.components)
}