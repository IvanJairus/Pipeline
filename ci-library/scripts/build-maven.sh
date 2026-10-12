#!/bin/bash
# Maven build for the standard and native builds
# Supports Nexus library deploy, OCP standard build, and OCP native build.
#
# Usage:
#   ./ci/scripts/build-maven.sh nexus <project_path>
#   ./ci/scripts/build-maven.sh standard <project_path>
#   ./ci/scripts/build-maven.sh native <project_path>

set -euo pipefail

JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/jdk-21.0.7}"
JAVA_HOME_NATIVE="${JAVA_HOME_NATIVE:-/usr/lib/jvm/graalvm-jdk-21.0.7+8.1/}"
MVN_HOME="${MVN_HOME:-/opt/maven/apache-maven-3.9.9}"
PATH_SETTING="${PATH_SETTING:-/root/.m2/settings-mobile.xml}"

###############################################################################
# build_nexus: build and deploy the Nexus library
#
# Input:  $1 = project directory path
# Commands: mvn clean package -U -DskipTests + mvn deploy
# Uses: JDK 21, settings-mobile.xml
###############################################################################
build_nexus() {
    local project_path="${1:?project_path required}"

    echo "Building Nexus library: ${project_path}..."
    rm -rf /root/.m2/repository/com/idp

    (
        cd "$project_path"
        MAVEN_HOME="${MVN_HOME}" \
        JAVA_HOME="${JAVA_HOME}" \
        PATH="${MVN_HOME}/bin:${PATH}" \
            mvn clean package -U -DskipTests

        MAVEN_HOME="${MVN_HOME}" \
        JAVA_HOME="${JAVA_HOME}" \
        PATH="${MVN_HOME}/bin:${PATH}" \
            mvn deploy
    )

    echo "Nexus library built and deployed: ${project_path}"
}

###############################################################################
# build_standard: standard Maven build for an OCP service
#
# Input:  $1 = project directory path
# Commands: mvn -s {settings} clean package -U -DskipTests
# Uses: JDK 21
###############################################################################
build_standard() {
    local project_path="${1:?project_path required}"

    echo "Building OCP service (standard): ${project_path}..."
    rm -rf /root/.m2/repository/com/idp

    (
        cd "$project_path"
        MAVEN_HOME="${MVN_HOME}" \
        JAVA_HOME="${JAVA_HOME}" \
        PATH="${MVN_HOME}/bin:${PATH}" \
            mvn -s "${PATH_SETTING}" clean package -U -DskipTests
    )

    echo "OCP service built (standard): ${project_path}"
}

###############################################################################
# build_native: native Maven build for an OCP service (GraalVM)
#
# Input:  $1 = project directory path
# Commands: mvn -s {settings} -Pnative -DskipTests -U native:compile
# Uses: GraalVM JDK 21
###############################################################################
build_native() {
    local project_path="${1:?project_path required}"

    echo "Building OCP service (native): ${project_path}..."
    rm -rf /root/.m2/repository/com/idp

    (
        cd "$project_path"
        MAVEN_HOME="${MVN_HOME}" \
        JAVA_HOME="${JAVA_HOME_NATIVE}" \
        PATH="${MVN_HOME}/bin:${PATH}" \
            mvn -s "${PATH_SETTING}" -Pnative -DskipTests -U native:compile
    )

    echo "OCP service built (native): ${project_path}"
}

###############################################################################
# build_tests: run the unit tests the package build skips
#
# The standard and native builds pass -DskipTests on purpose: an image has to be
# built once and only once, and a test that fails after the layer exists is a
# wasted artifact. So the tests get their own invocation, and the pipeline that
# wants them asks for them by name.
#
# Input:  $1 = project directory path
# Commands: mvn -s {settings} test
###############################################################################
build_tests() {
    local project_path="${1:?project_path required}"

    echo "Running unit tests: ${project_path}..."
    (
        cd "$project_path"
        MAVEN_HOME="${MVN_HOME}" \
        JAVA_HOME="${JAVA_HOME}" \
        PATH="${MVN_HOME}/bin:${PATH}" \
            mvn -s "${PATH_SETTING}" test
    )
    echo "Unit tests finished: ${project_path}"
}

###############################################################################
# build_contracts: consumer-contract verification against the provider stub
#
# Input:  $1 = project directory path
# Commands: mvn -s {settings} verify -Pcontracts
###############################################################################
build_contracts() {
    local project_path="${1:?project_path required}"

    echo "Verifying consumer contracts: ${project_path}..."
    (
        cd "$project_path"
        MAVEN_HOME="${MVN_HOME}" \
        JAVA_HOME="${JAVA_HOME}" \
        PATH="${MVN_HOME}/bin:${PATH}" \
            mvn -s "${PATH_SETTING}" verify -Pcontracts
    )
    echo "Contracts verified: ${project_path}"
}

# If called directly (not sourced), dispatch by build type
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    build_type="${1:?Usage: build-maven.sh <nexus|standard|native|package|test|contracts> <project_path>}"
    project_path="${2:?project_path required}"

    case "$build_type" in
        nexus)     build_nexus "$project_path" ;;
        standard)  build_standard "$project_path" ;;
        native)    build_native "$project_path" ;;
        # "package" is the name the stage templates use for the artifact build.
        # It is the same build the OCP path runs; the alias exists so the stage
        # reads like the pipeline rather than like the tool.
        package)   build_standard "$project_path" ;;
        test)      build_tests "$project_path" ;;
        contracts) build_contracts "$project_path" ;;
        *)         echo "ERROR: Unknown build type: ${build_type}. Use nexus|standard|native|package|test|contracts" >&2; exit 1 ;;
    esac
fi
