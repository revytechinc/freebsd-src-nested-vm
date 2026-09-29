// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2026 REVYTECH, Inc.
//
// CloudBSD CI: the FreeBSD base system (pkgbase), built from THIS tree and
// published to InternalPkg. Discovered by the Jenkins GitHub organization
// folder (repository topic `cloudbsd-ci`, branch `main`); nothing about this
// job lives in cloudbsd-ci. Scripts: tools/cloudbsd-ci/pkgbase/ (README there).
//
//   make buildworld buildkernel      (unprivileged; objects beside the workspace)
//   make packages                    (-DNO_ROOT staging; REPODIR beside the workspace)
//
// Package names are FreeBSD's own (FreeBSD-runtime, FreeBSD-kernel-generic,
// ...): the fleet already runs pkgbase from pkg.FreeBSD.org's base_latest,
// and an upgrade has to replace THOSE packages. (tests/sys/vmm/nested/
// scripts/build_packages.sh builds only CloudBSD-kernel-generic and
// CloudBSD-bhyve for the nested lane; it is not a base system.)
//
// WHERE IT GOES: InternalPkg (pkg.internal.revytechinc.com, the pkgrepo jail
// on freedev008) as the SEPARATE repository ${ABI}/base_latest -- FreeBSD's
// own pkgbase naming. Never the ports `latest` repository, never public
// pkg.cloudbsd.org. Signed with the existing InternalPkg key where it lives;
// this job never sees the key.
//
// HOW IT GETS THERE (PUBLISH_VIA):
//   handoff       Default today. Packages stay beside the workspace on the
//                 builder; the job prints the exact commands and WAITS (input,
//                 no executor held) until an operator has run them on
//                 freedev008. "Built" and "published" must not arrive in the
//                 same shape.
//   pkgrepo-node  Once a node carries the `pkgrepo` role label (Track #396):
//                 root pulls the packages into a root-owned staging directory
//                 there and runs publish-internal-repo.sh -d .../base_latest.
//
// WHERE IT RUNS: the amd64 BUILDER POOL (cloudbsd-ci jenkins/casc/jenkins.yaml,
// Track #396). The build locks ONE free resource labelled
// poudriere-amd64-builders (each is poudriere-amd64-<node>, the same lock
// poudriere takes there) and then runs on the node that resource names. The
// lock picks the node, not the scheduler, so pkgbase never pins one builder
// while the other sits idle, and never shares a builder with a poudriere bulk.
//
// MEMORY: the builders also host the Jenkins controller jail (freedev005).
// On 2026-09-29 a -j<ncpu> world build plus `make packages` with -T0
// compression pushed freedev005 out of swap, and the OOM killer took the
// controller. build.sh therefore caps parallelism by cores AND memory (see
// MAKE_JOBS) and packages with few jobs and few compression threads.

// Mirrors builderAgentLabel() in cloudbsd-ci jenkins/Jenkinsfile.port: the
// locked resource name becomes part of a label EXPRESSION, so check its shape.
String builderAgentLabel(String locked) {
    String prefix = 'poudriere-amd64-'
    String r = (locked ?: '').trim()
    if (!r.startsWith(prefix)) {
        error("locked builder resource '${r}' is not ${prefix}<node>")
    }
    String node = r.substring(prefix.length())
    if (!(node ==~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/)) {
        error("locked builder resource '${r}' does not name a plain node")
    }
    if (node.startsWith('poudriere') || node.endsWith('-builders')) {
        error("locked builder resource '${r}' names a label, not a builder node")
    }
    return node + ' && poudriere-amd64'
}

pipeline {
    agent none

    options {
        timestamps()
        // World + kernel + packages from clean is ~1-2h on 64 cores, much
        // longer on a contended builder. The handoff gate has its own timeout.
        timeout(time: 30, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '20'))
        // The handoff reads this build's output directory; a second run would
        // clean it underneath the pull.
        disableConcurrentBuilds()
        // Checkout only where the tree is needed (the build). The publish
        // node must not clone a whole src tree to run one script.
        skipDefaultCheckout()
    }

    parameters {
        string(
            name: 'KERNCONF',
            defaultValue: 'GENERIC',
            description: 'Kernel configuration packaged as FreeBSD-kernel-*.')
        booleanParam(
            name: 'CLEAN_OBJ',
            defaultValue: true,
            description: 'Remove the object tree before building. On by default: a base shipped fleet-wide is built from clean. Off reuses it (META_MODE) for a faster rebuild.')
        booleanParam(
            name: 'PUBLISH',
            defaultValue: true,
            description: 'Publish to InternalPkg FreeBSD:16:amd64/base_latest (never the ports latest repo, never public). Off: build only.')
        choice(
            name: 'PUBLISH_VIA',
            choices: ['handoff', 'pkgrepo-node'],
            description: 'handoff: documented root step on freedev008, the job waits for it. pkgrepo-node: automatic, on the node carrying the pkgrepo label (Track #396).')
        string(
            name: 'MAKE_JOBS',
            defaultValue: '0',
            description: 'make -j for buildworld/buildkernel. 0 = auto: min(cores/2, RAM GiB/4). The builders host other jobs and the controller jail; do not set this to the core count.')
        choice(
            name: 'LLVM_TARGETS',
            choices: ['host-only', 'all'],
            description: 'host-only (WITHOUT_LLVM_TARGET_ALL): the shipped clang/lld target amd64 only; buildworld still builds its own cross toolchain for other architectures. Much less build time and memory. all: every LLVM target, like pkg.FreeBSD.org.')
        string(
            name: 'HANDOFF_WAIT_HOURS',
            defaultValue: '12',
            description: 'How long the handoff gate waits for the operator before the build is aborted. The packages stay on the builder until the next build either way.')
    }

    environment {
        BASE_REPO_NAME = 'base_latest'
    }

    stages {
        stage('Validate inputs') {
            steps {
                script {
                    if (!(params.KERNCONF ==~ /^[A-Z0-9_-]+$/)) {
                        error("KERNCONF is not a usable kernel config name: ${params.KERNCONF}")
                    }
                    if (!(params.MAKE_JOBS ==~ /^[0-9]{1,3}$/)) {
                        error("MAKE_JOBS must be 0 (auto) or a job count: ${params.MAKE_JOBS}")
                    }
                    if (!(params.HANDOFF_WAIT_HOURS ==~ /^[1-9][0-9]?$/)) {
                        error("HANDOFF_WAIT_HOURS must be 1-99: ${params.HANDOFF_WAIT_HOURS}")
                    }
                }
            }
        }

        stage('Build base') {
            // Builder pool (see the header). Stage options are evaluated BEFORE
            // the stage agent is allocated: the lock is held first, then the
            // agent label is derived from the locked resource. The lock covers
            // checkout, build and record; the handoff below only reads the
            // output directory, which disableConcurrentBuilds() protects.
            options {
                lock(label: 'poudriere-amd64-builders', quantity: 1, variable: 'BUILDER')
            }
            agent { label builderAgentLabel(env.BUILDER) }
            environment {
                SRC_DIR            = "${WORKSPACE}"
                PKGBASE_ARTIFACTS  = "${WORKSPACE}/ci-artifacts"
                // Outside the source tree, so the tree stays clean and a
                // checkout never walks the object tree.
                MAKEOBJDIRPREFIX   = "${WORKSPACE}@pkgbase/obj"
                PKGBASE_REPODIR    = "${WORKSPACE}@pkgbase/repo"
                TARGET             = 'amd64'
                TARGET_ARCH        = 'amd64'
                PKGBASE_MAKE_JOBS  = "${params.MAKE_JOBS}"
                PKGBASE_LLVM_TARGETS = "${params.LLVM_TARGETS}"
            }
            steps {
                script {
                    if (env.BUILDER != ('poudriere-amd64-' + env.NODE_NAME)) {
                        error("holding builder lock ${env.BUILDER} but running on ${env.NODE_NAME}")
                    }
                    echo "builder lock ${env.BUILDER} held; building on ${env.NODE_NAME}"
                }
                checkout scm
                sh 'sh tools/cloudbsd-ci/pkgbase/stamp.sh'
                sh 'sh tools/cloudbsd-ci/pkgbase/preflight.sh'
                sh 'sh tools/cloudbsd-ci/pkgbase/build.sh'
                sh 'sh tools/cloudbsd-ci/pkgbase/record.sh'
                archiveArtifacts artifacts: 'ci-artifacts/**', fingerprint: true, allowEmptyArchive: false
                script {
                    // key=value lines from record.sh. Not readProperties: that
                    // is pipeline-utility-steps, which the controller does not run.
                    def rec = [:]
                    readFile('ci-artifacts/pkgbase-build.properties').split('\n').each { line ->
                        def i = line.indexOf('=')
                        if (i > 0) { rec[line.substring(0, i)] = line.substring(i + 1) }
                    }
                    ['pkgdir', 'version', 'commit', 'short', 'abi', 'count'].each { k ->
                        if (!rec[k]) { error("record.sh did not record ${k}") }
                    }
                    env.PKGBASE_BUILDER = env.NODE_NAME
                    env.PKGBASE_SRCDIR  = rec['pkgdir']
                    env.PKGBASE_VERSION = rec['version']
                    env.PKGBASE_COMMIT  = rec['commit']
                    env.PKGBASE_ABI     = rec['abi']
                    env.PKGBASE_COUNT   = rec['count']
                    currentBuild.description = "${rec['version']} @ ${rec['short']} on ${env.NODE_NAME} (${rec['count']} pkgs)"
                }
            }
        }

        stage('Publish: handoff') {
            when {
                beforeAgent true
                allOf {
                    expression { return params.PUBLISH }
                    expression { return params.PUBLISH_VIA == 'handoff' }
                }
            }
            steps {
                echo """InternalPkg base handoff -- on freedev008, as an operator with sudo on both hosts
(the tar stream is written by ROOT into a ROOT-owned directory; the key never moves):
  STAGE=/var/db/pkgbase-handoff/${env.PKGBASE_VERSION}
  sudo install -d -o root -g wheel -m 0755 "\$STAGE"
  ssh ${env.PKGBASE_BUILDER}.cloudbsd.org 'sudo tar -C "${env.PKGBASE_SRCDIR}" -cf - .' | sudo tar -C "\$STAGE" -xf -
  sudo /usr/local/sbin/publish-internal-repo.sh -s "\$STAGE" -d /usr/local/bastille/jails/pkgrepo/root/usr/local/www/pkgrepo/${env.PKGBASE_ABI}/${env.BASE_REPO_NAME}
Wait for PUBLISH_OK, then check https://pkg.internal.revytechinc.com/${env.PKGBASE_ABI}/${env.BASE_REPO_NAME}/
lists FreeBSD-*-${env.PKGBASE_VERSION}.pkg (tools/cloudbsd-ci/pkgbase/README.md, 'Publishing')."""
                timeout(time: Integer.parseInt(params.HANDOFF_WAIT_HOURS), unit: 'HOURS') {
                    input message: "Published ${env.PKGBASE_COUNT} base packages ${env.PKGBASE_VERSION} into InternalPkg ${env.PKGBASE_ABI}/${env.BASE_REPO_NAME}, and publish-internal-repo.sh printed PUBLISH_OK?",
                          ok: 'PUBLISH_OK seen'
                }
            }
        }

        stage('Publish: pkgrepo node') {
            when {
                beforeAgent true
                allOf {
                    expression { return params.PUBLISH }
                    expression { return params.PUBLISH_VIA == 'pkgrepo-node' }
                }
            }
            agent { label 'pkgrepo' }
            steps {
                // readTrusted: the script from this branch's SCM, without a checkout.
                writeFile file: 'pkgbase-publish-pkgrepo.sh', text: readTrusted('tools/cloudbsd-ci/pkgbase/publish-pkgrepo.sh')
                lock(resource: 'cloudbsd-pkgbase-publish') {
                    sh 'sh pkgbase-publish-pkgrepo.sh'
                }
            }
        }
    }

    post {
        always {
            echo "cloudbsd pkgbase: branch=${env.BRANCH_NAME} publish=${params.PUBLISH} via=${params.PUBLISH_VIA}"
        }
    }
}
