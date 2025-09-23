

{
    generate_manifest(pim, config, components): [
        component.generate_manifest(pim, config),
        for component in components
    ],
}