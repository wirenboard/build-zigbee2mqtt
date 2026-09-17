// FIXME: generalize this pipeline some day for other 3rdparties

pipeline {
    agent {
        label "${params.BUILD_NODE_LABEL}"
    }
    options {
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '30'))
        // A build takes 10 to 15 minutes; anything past two hours is stuck, usually in qemu
        timeout(time: 2, unit: 'HOURS')
    }
    parameters {
        string(name: 'REPO', defaultValue: 'https://github.com/Koenkk/zigbee2mqtt', description: 'Repo to get zigbee2mqtt from')
        string(name: 'BRANCH', defaultValue: 'master', description: 'For checkout step')
        string(name: 'TAG', defaultValue: '', description: 'Use with VERSION_TO_NAME to build custom version (leave empty for find and use latest tag automatically)')
        booleanParam(name: 'VERSION_TO_NAME', defaultValue: false, description: 'Adds version number to package name as suffix, creating names like zigbee2mqtt-1.18.1')
        booleanParam(name: 'ADD_VERSION_SUFFIX', defaultValue: true, description: 'For dev branches only')
        string(name: 'WB_REVISION', defaultValue: '-wb101', description: 'For rebuilds, like -wb101')
        string(name: 'WBDEV_IMAGE', defaultValue: '', description: 'Docker image to use as devenv')
        string(name: 'WBDEV_TESTING_SETS', defaultValue: '',
                description: 'Comma-separated testing set names: their experimental.<name> repositories are added to the rootfs above testing and unstable, so packages from them win. Trixie targets only. With UPLOAD_TO_POOL only for an ~exp~ version, which reaches testing sets and nothing else')
        choice(name: 'WBDEV_TARGET', choices: ['trixie-armhf', 'trixie-arm64', 'bullseye-armhf', 'bullseye-arm64'], description: 'Target architecture')
        choice(name: 'NODEJS_MAJOR_VERSION',
                choices: ['24', '22', '16'],
                description: '''Node.js major the build installs and the package requires. build.sh turns it into an apt dependency, 24 becomes nodejs (>= 24), nodejs (<< 25):
- 24 (default): trixie only, Node 24 needs glibc 2.38. A version the repositories do not have yet comes from WBDEV_TESTING_SETS
- 22: from the Wiren Board repositories, trixie and bullseye
- 16: the separate nodejs-16 package, for zigbee2mqtt 1.18.1''')
        booleanParam(name: 'USE_TESTING_REPOSITORY', defaultValue: true,
            description: 'Use dependencies from unstable repo if necessary (with lower priority)')
        string(name: 'NPM_REGISTRY', defaultValue: '',
                description: 'Select alternative mirror if necessary, e.g. https://registry.npmjs.org/, http://r.cnpmjs.org/')
        choice(name: 'BUILD_NODE_LABEL',
                choices: ['devenv', 'heavy-duty'],
                description: '''Build machines: a Jenkins label, any free machine with it is used:
- devenv (default): 16 cores, 31 GB, the machines regular Wiren Board package builds use
- heavy-duty: 24 cores, 115 GB, one machine shared with the hours-long Node.js builds''')
        booleanParam(name: 'UPLOAD_TO_POOL', defaultValue: false,
                description: 'Upload the .deb to the apt pool at the end of the build. Off by default to keep the pool safe. With WBDEV_TESTING_SETS needs ADD_VERSION_SUFFIX')
        booleanParam(name: 'FORCE_OVERWRITE', defaultValue: false,
                description: 'With UPLOAD_TO_POOL: replace the same version already in the pool')
    }
    environment {
        PROJECT_SUBDIR = 'zigbee2mqtt'
        RESULT_SUBDIR = 'result'

        // The rootfs of the build, shared by Build and Test deb: the package is checked on the
        // very Node.js it was built with
        WBDEV_BUILD_METHOD = "qemuchroot"
        WBDEV_USE_UNSTABLE_DEPS = "${params.USE_TESTING_REPOSITORY ? 'y' : ''}"
        // Initialize params as envvars, workaround for bug https://issues.jenkins-ci.org/browse/JENKINS-41929
        WBDEV_IMAGE = "${params.WBDEV_IMAGE ?: (params.WBDEV_TARGET.startsWith('bullseye') ? 'contactless/devenv:latest_bullseye' : 'contactless/devenv:latest')}"
        WBDEV_TARGET = "${params.WBDEV_TARGET}"
        WBDEV_TESTING_SETS = "${params.WBDEV_TESTING_SETS}"
    }
    stages {
        stage('Initialize build') { steps {
            script {
                // These values go into shell command lines: allow only what they legitimately contain
                def formats = [
                    TAG:          /^[A-Za-z0-9._\/+-]*$/,
                    WB_REVISION:  /^-wb\d+$/,
                    WBDEV_IMAGE:  /^[A-Za-z0-9._\/:@-]*$/,
                    NPM_REGISTRY: /^(https?:\/\/[A-Za-z0-9._~:\/@%+-]+)?$/,
                ]
                formats.each { name, format ->
                    if (!("${params[name]}" ==~ format)) {
                        error("${name}='${params[name]}' does not match ${format}.")
                    }
                }

                if (params.WBDEV_TARGET.startsWith('bullseye') && params.NODEJS_MAJOR_VERSION.toInteger() >= 24) {
                    error("NODEJS_MAJOR_VERSION=${params.NODEJS_MAJOR_VERSION} for ${params.WBDEV_TARGET}: Node.js 24 needs glibc 2.38, bullseye has 2.31")
                }

                def repoType = params.USE_TESTING_REPOSITORY ? "testing" : "stable"
                def buildName = "#${BUILD_NUMBER}:${params.WBDEV_TARGET}/${repoType}"
                if (params.TAG) {
                    buildName += " custom_tag=${params.TAG}"
                }
                def description = "Build on Node.js ${params.NODEJS_MAJOR_VERSION} for ${params.WBDEV_TARGET}"

                def testingSets = params.WBDEV_TESTING_SETS.trim()
                if (testingSets) {
                    // Such a package may need what only the set has, so it must stay out of the regular
                    // repositories. An ~exp~ version does: staging drops those, unstable follows staging
                    def exp = params.ADD_VERSION_SUFFIX && !wb.isBranchRelease(env.BRANCH_NAME)
                    if (params.UPLOAD_TO_POOL && !exp) {
                        error("UPLOAD_TO_POOL with WBDEV_TESTING_SETS needs an ~exp~ version: " +
                              "ADD_VERSION_SUFFIX on a non-release branch.")
                    }
                    // devenv checks the names itself; images without PR #284 ignore the sets in wbdev chroot
                    if (params.WBDEV_TARGET.startsWith('bullseye') && !params.WBDEV_IMAGE) {
                        error("WBDEV_TESTING_SETS: contactless/devenv:latest_bullseye used for ${params.WBDEV_TARGET} does not add testing sets in wbdev chroot")
                    }
                    buildName += " testing_sets=${testingSets}"
                    description += ", testing sets: ${testingSets}"
                }
                currentBuild.displayName = buildName
                currentBuild.description = description
            }
        }}
        stage('Cleanup workspace') { steps {
            cleanWs deleteDirs: true, patterns: [[pattern: "$RESULT_SUBDIR", type: 'INCLUDE']]
        }}
        stage('Checkout') { steps { dir("$PROJECT_SUBDIR") {
            git branch: params.BRANCH, url: params.REPO
        }}}
        stage('Find latest tag') {
            when { expression {
                params.TAG == ""
            }}
            steps { dir("$PROJECT_SUBDIR") { script {
                sshagent (credentials: ['jenkins-github-public-ssh']) {
                    sh 'git config --add remote.origin.fetch "+refs/tags/*:refs/tags/*" && git fetch --all'
                    env.LATEST_TAG = sh(returnStdout: true, script: "git tag --sort=-creatordate | head -n 1").trim()
                    echo "Found latest tag: ${env.LATEST_TAG}"

                    currentBuild.displayName += " latest_tag=${env.LATEST_TAG}"
                }
            }}}
        }
        stage('Checkout tag') {
            when { expression {
                (params.TAG != "") || (env.LATEST_TAG != null)
            }}
            steps { dir("$PROJECT_SUBDIR") {
                sshagent (credentials: ['jenkins-github-public-ssh']) {
                    sh 'git config --add remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" && git fetch --all'
                    script {
                        def tagToUse = params.TAG ?: env.LATEST_TAG
                        echo "Checking out tag: ${tagToUse}"
                        sh "git checkout ${tagToUse}"
                    }
                }
                sh 'git clean -xdf'

                // FIXME: this output need for catch bug when result
                //        deb package increase to x2, for example
                //        normal sise is 27mb, but generate 54mb.
                //        in big packet we can find pnpm pakages dublicates
                echo "File list before build start:"
                sh "ls -lahR --color=auto"
            }}
        }
        stage('Determine version suffix (this repo)') {
            when { expression {
                params.ADD_VERSION_SUFFIX && !wb.isBranchRelease(env.BRANCH_NAME)
            }}
            steps { script {
                sshagent (credentials: ['jenkins-github-public-ssh']) {
                    sh 'git config --add remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" && git fetch --all'
                }
                env.WB_VERSION_SUFFIX = wb.makeVersionSuffixFromBranch(wb.getMainBranchName())
            }}
        }
        stage('Determine version') {
            steps { dir("$PROJECT_SUBDIR") { script {
                sshagent (credentials: ['jenkins-github-public-ssh']) {
                    sh 'git config --add remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" && git fetch --all'
                }
                env.PURE_VERSION = sh(returnStdout: true, script: "git describe --tags | sed 's/zigbee2mqtt-//'").trim()
                env.VERSION = env.PURE_VERSION + params.WB_REVISION + (env.WB_VERSION_SUFFIX ?: '')
                echo "Pure version: $PURE_VERSION"
                echo "Version with suffix: $VERSION"
            }}}
        }
        stage('Build') {
            steps { script {
                def name = params.VERSION_TO_NAME ? "zigbee2mqtt-${PURE_VERSION}" : "zigbee2mqtt";
                def specialParams = "";
                if (params.VERSION_TO_NAME) {
                    specialParams = "--provides zigbee2mqtt --conflicts zigbee2mqtt --replaces zigbee2mqtt"
                }

                sh "printenv | sort"
                sh "wbdev root printenv | sort"
                sh """wbdev chroot bash -c \\
                          "NODEJS_MAJOR_VERSION='${params.NODEJS_MAJOR_VERSION}' \\
                          NPM_REGISTRY='${params.NPM_REGISTRY}' \\
                          ./build.sh ${name} ${VERSION} ${PROJECT_SUBDIR} ${RESULT_SUBDIR} ${specialParams}" """
            }}
            post {
                always {
                    sh 'wbdev root chown -R jenkins:jenkins .'
                }
                success {
                    archiveArtifacts artifacts: "$RESULT_SUBDIR/*.deb"
                }
            }
        }
        // Nothing leaves the build unchecked: the package is opened on the same rootfs, and its
        // native modules are loaded on the Node.js it declares
        stage('Test deb') {
            steps {
                sh """wbdev chroot bash -c \\
                          "NODEJS_MAJOR_VERSION='${params.NODEJS_MAJOR_VERSION}' \\
                          ./test-deb.sh ${RESULT_SUBDIR}" """
            }
            post {
                always {
                    sh 'wbdev root chown -R jenkins:jenkins .'
                }
            }
        }
        // wbDeploy uploads every archived .deb of this build, which is why only result/*.deb is archived
        stage('Setup deploy') {
            when { expression {
                params.UPLOAD_TO_POOL
            }}
            steps { script {
                wbDeploy projectSubdir: env.PROJECT_SUBDIR,
                        forceOverwrite: params.FORCE_OVERWRITE,
                        withGithubRelease: false
            }}
        }
    }
}
