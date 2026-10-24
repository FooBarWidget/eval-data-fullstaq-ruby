# Build workflow management

## What is build workflow management?

Building packages involves [multiple steps](build-steps.md), some of which have dependencies, and some of which must be run multiple times (e.g. once per distribution, variant, Ruby version). The entire _workflow_ of building all packages that we intend to build, means:

 * Running the steps in the right order.
 * Ensuring that each step's output is properly passed to its depending steps as input.
 * Running a step the proper number of times, each time against the proper distribution, variant and Ruby version.

The parameters for the workflow are defined in `config.yml`. This file defines:

 * Which Ruby versions we want to build packages for.
 * Which variants we want to build packages for.
 * Which distributions we want to build packages for.

## Why build workflow management is needed

Workflow management is needed because, given the number of Ruby versions, variants and distributions we want to package for, it's very easy to reach a huge combinatorial explosion.

For example, suppose that want to support Ruby 2.6.6 and 2.7.1 only, on Debian 9 and 10 only. We'll have to run the "Build Ruby" step at least `num_ruby_versions * num_distributions * num_variants = 2 * 2 * 3 = 12` times:

 * Ruby 2.6.6 + Debian 9 + normal variant
 * Ruby 2.6.6 + Debian 9 + malloctrim variant
 * Ruby 2.6.6 + Debian 9 + jemalloc variant
 * Ruby 2.6.6 + Debian 10 + normal variant
 * Ruby 2.6.6 + Debian 10 + malloctrim variant
 * Ruby 2.6.6 + Debian 10 + jemalloc variant
 * Ruby 2.7.1 + Debian 9 + normal variant
 * Ruby 2.7.1 + Debian 9 + malloctrim variant
 * Ruby 2.7.1 + Debian 9 + jemalloc variant
 * Ruby 2.7.1 + Debian 10 + normal variant
 * Ruby 2.7.1 + Debian 10 + malloctrim variant
 * Ruby 2.7.1 + Debian 10 + jemalloc variant

This is already a pretty big list. It's pretty cumbersome to manually run the "Build Ruby" step so many times, each time with the proper parameters, and hoping that we didn't make a mistake.

It gets worse very quikcly. Let's say the next day we want to support Ruby 2.7.2 and CentOS 8 too. That results in `num_ruby_versions * num_distributions * num_variants = 3 * 3 * 3 = 27` combinations. Just by adding 1 Ruby version and 1 distribution to support, we've more than doubled the amount of combinations.

The more "stuff" we support, the more quickly the number rises! Clearly, some sort of automation is needed, which takes care of not only calculating what all the different combinations are, but also running the build steps with the proper parameters.

## Implementation

In our codebase, workflow management is separated from step execution. This means that the build scripts for the individual steps (e.g. `build-ruby`) know nothing about config.yml. These scripts accept parameters, and it is up to a higher workflow management system to pass the right parameters.

The workflow management system is implemented in Github Workflow, in `.github/workflows/ci-cd-*.yml.erb`. These are ERB templates that, given the parameters in `config.yml`, outputs a bunch of Github Workflow YAML files that roughly implements the build pipeline described in [Build steps](build-steps.md):

![](build-steps.png)

The ERB templates are run by `./internal-scripts/generate-ci-cd-yaml.rb`. It is recommended that you [setup a Git hook](dev-environment-setup.md), which runs that script automatically before every commit, so that the Github workflow file gets properly updated whenever you either modify the ERB template, or config.yml.

The `CI/CD: prepare` workflow runs `internal-scripts/ci-cd/check-version-numbers-need-changing/check-package-versions.rb` to reject package version downgrades and require version bumps when upstream sources change. For Ruby packages, the package-manager version is the revision; common and Rbenv packages have a separate upstream version and revision. The check compares `config.yml` against both the default branch and the latest release; a default-branch push uses its pre-push state instead of comparing against itself. The same command checks build-script changes against the release and requests manual approval when packages have not been bumped. A failure prevents the pipeline from advancing to the Ruby package builds.

The policy and package-manager ordering code live in `lib/package_version_check.rb` and `lib/package_version_order.rb`. Their Minitest specs live in `test/`; run both suites with `ruby test/run.rb`, or run a single suite with `ruby test/package_version_check_test.rb` or `ruby test/package_version_order_test.rb`. To check locally against a particular baseline, pass its Git ref to `check-package-versions.rb`.

After changing version ordering, run `ruby test/check_version_order_references.rb` to compare it against host `dpkg` and RPM's published comparison cases. This optional check requires `dpkg` and network access; the regular unit tests do not.
