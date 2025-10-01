//
//  An ingress definition for WiseFood deployments.
//

local k = import "k.libsonnet";

local ing = k.networking.v1.ingress;
local ingrule = k.networking.v1.ingressRule;
local ingpath = k.networking.v1.httpIngressPath;
local ingtls = k.networking.v1.ingressTLS;


local standard_annotations =  {
    "nginx.ingress.kubernetes.io/proxy-connect-timeout": "60s",
};

local letsencrypt_annotations = {
    "cert-manager.io/cluster-issuer": "letsencrypt-production",
    "nginx.ingress.kubernetes.io/ssl-redirect": "true",
};

local http_ingress(name, annotations, host, paths) = 
    ing.new(name)
    + ing.metadata.withAnnotations(standard_annotations + annotations)
    + ing.spec.withIngressClassName("nginx")
    + ing.spec.withRules(
        ingrule.withHost(host)
        + ingrule.http.withPaths(paths)
    )
;

local https_ingress_lets_encrypt(name, annotations, host, paths, tls_name) = 
    ing.new(name)
    + ing.metadata.withAnnotations(standard_annotations + letsencrypt_annotations + annotations)
    + ing.spec.withIngressClassName("nginx")
    + ing.spec.withRules(
        ingrule.withHost(host)
        + ingrule.http.withPaths(paths)
    )
    + ing.spec.withTls([
        ingtls.withHosts([host])
        + ingtls.withSecretName(tls_name),
    ])
;

local pim_tls_secret_name(pim) =  pim.namespace+'-tls';

local transform_paths(paths) = [
    ingpath.withPath(p[0])
    + ingpath.withPathType(p[1])
    + ingpath.backend.service.withName(p[2])
    + ingpath.backend.service.port.withName(p[3])

    for p in paths
];

local ingress(pim, config, name, annotations, host, paths) = 
    if (config.dns.SCHEME == 'http')
    then http_ingress(name, annotations, host, transform_paths(paths))
    else https_ingress_lets_encrypt(name, annotations, host, transform_paths(paths), 
        pim_tls_secret_name(pim))
;

{
    generate_manifest(pim, config): {

        ingress_s3: ingress(pim, config, 
            "s3",
            annotations = {
                "nginx.ingress.kubernetes.io/proxy-body-size": "5120m",
                "nginx.ingress.kubernetes.io/proxy-http-version": "1.1",
                "nginx.ingress.kubernetes.io/proxy-chunked-transfer-encoding": "off",
                "nginx.ingress.kubernetes.io/proxy-set-header": "Host $http_host; X-Real-IP $remote_addr; X-Forwarded-For $proxy_add_x_forwarded_for; X-Forwarded-Proto $scheme;",
                "nginx.ingress.kubernetes.io/proxy-set-headers": "Connection '';",
                "nginx.ingress.kubernetes.io/rewrite-target": "/$1",
            },
            host = config.dns.MINIO_SUBDOMAIN+'.'+config.dns.ROOT_DOMAIN,
            paths = [
                ["/console/?(.*)",        "ImplementationSpecific", "minio", "minio-minio"],
                ["/", "Prefix", "minio", "minio-minapi"]
            ]
        ),

        ingress_kc: ingress(pim, config,
            "kc",
            annotations = {},
            host = config.dns.KEYCLOAK_SUBDOMAIN+'.'+config.dns.ROOT_DOMAIN,
            paths = [
                ["/", "Prefix", "keycloak", "keycloak-kc"]
            ]
        ),

        ingress: ingress(pim, config, 
            "wisefood",
            annotations = {
                "nginx.ingress.kubernetes.io/x-forwarded-prefix": "/$1",
                "nginx.ingress.kubernetes.io/rewrite-target": "/$3",
                "nginx.ingress.kubernetes.io/proxy-body-size": "1920m",
                "nginx.ingress.kubernetes.io/proxy-buffering": "off",
                "nginx.ingress.kubernetes.io/proxy-request-buffering": "off",

            },
            host = config.dns.ROOT_DOMAIN, 
            paths = [
                ["/(dc)(/|$)(.*)", "ImplementationSpecific", "data-catalog", "catalog-dc"],
            ]
        ),
    }    
}
