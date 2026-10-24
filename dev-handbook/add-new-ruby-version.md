# Adding support for a new Ruby version

To add support for a new Ruby version, open `config.yml` and add it to the `ruby` section. Make sure you update both `minor_version_packages` and `tiny_version_packages`.

Under `minor_version_packages`, increase `package_revision` whenever you change an existing entry's `full_version`. Never reset or lower the revision for the same `minor_version`: for example, updating Ruby `4.0.6` at revision `4` to Ruby `4.0.9` requires revision `5` or higher, not `0`.

New minor series may start at revision `0`. Under `tiny_version_packages`, a new `full_version` also creates a new package name and may start at revision `0`. In contrast, the common and Rbenv packages keep their names when their package version increases, so they may reset the revision with that increase.

After editing `config.yml`, regenerate workflows with `./internal-scripts/generate-ci-cd-yaml.rb` and commit the generated files too.
