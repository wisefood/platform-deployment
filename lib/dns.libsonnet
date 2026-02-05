local k = import 'k.libsonnet';


local k = import 'k.libsonnet';

{
  root_domain(config): config.dns.ROOT_DOMAIN,
  
  kc_domain(config):
    local parts = std.split(config.dns.ROOT_DOMAIN, '.');
    if std.length(parts) > 2
    then config.dns.KEYCLOAK_SUBDOMAIN + '.' + std.join('.', std.slice(parts, 1, std.length(parts), 1))
    else config.dns.KEYCLOAK_SUBDOMAIN + '.' + config.dns.ROOT_DOMAIN,

  s3_domain(config): 
    local parts = std.split(config.dns.ROOT_DOMAIN, '.');
    if std.length(parts) > 2
    then config.dns.MINIO_SUBDOMAIN + '.' + std.join('.', std.slice(parts, 1, std.length(parts), 1))
    else config.dns.MINIO_SUBDOMAIN + '.' + config.dns.ROOT_DOMAIN,

  root_domain_scheme(config):
    config.dns.SCHEME + '://' + config.dns.ROOT_DOMAIN,

  kc_domain_scheme(config):
    config.dns.SCHEME + '://' + $.kc_domain(config),
    
  s3_domain_scheme(config): 
    config.dns.SCHEME + '://' + $.s3_domain(config),

  api_url_scheme(config):
    config.dns.SCHEME + '://' + config.dns.ROOT_DOMAIN + '/dc/api',
  
  core_api_url_scheme(config):
    config.dns.SCHEME + "://" + config.dns.ROOT_DOMAIN + '/rest',
}
// Example usage:
// local dns = import 'dns.libsonnet';
// local config = {
//   dns: {
//     ROOT_DOMAIN: 'example.com',
//     KEYCLOAK_SUBDOMAIN: 'auth',
//     MINIO_SUBDOMAIN: 'storage',
//   }
// };
// dns.root_domain(config)  // Returns: 'example.com'
// dns.kc_domain(config)    // Returns: 'auth.example.com'
// dns.s3_domain(config)    // Returns: 'storage.example.com'

// Example usage with double-level subdomain:
// local config2 = {
//   dns: {
//     ROOT_DOMAIN: 'sub.example.com',
//     KEYCLOAK_SUBDOMAIN: 'auth',
//     MINIO_SUBDOMAIN: 'storage',
//   }
// };
// dns.root_domain(config2)  // Returns: 'sub.example.com'
// dns.kc_domain(config2)    // Returns: 'auth.example.com'
// dns.s3_domain(config2)    // Returns: 'storage.example.com' 