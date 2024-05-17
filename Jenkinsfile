// FIXME: generalize this pipeline some day for other 3rdparties

pipeline {
    agent {
        label 'devenv'
    }
    parameters {
        string(name: 'REPO', defaultValue: 'https://github.com/Koenkk/zigbee2mqtt', description: 'repo to get zigbee2mqtt from')
        string(name: 'BRANCH', defaultValue: 'master', description: 'for checkout step')
        string(name: 'TAG', defaultValue: '', description: 'use with VERSION_TO_NAME to build custom version')
        booleanParam(name: 'VERSION_TO_NAME', defaultValue: false, description: 'build package like zigbee2mqtt-1.18.1')
        booleanParam(name: 'UPLOAD_TO_POOL', defaultValue: false, description: 'disabled by default for repo safety')
        booleanParam(name: 'FORCE_OVERWRITE', defaultValue: false,
                description: 'use only you know what you are doing, replace existing version of package')
        booleanParam(name: 'ADD_VERSION_SUFFIX', defaultValue: true, description: 'for dev branches only')
        string(name: 'WB_REVISION', defaultValue: '-wb101', description: 'for rebuilds, like -wb101')
        string(name: 'WBDEV_IMAGE', defaultValue: 'contactless/devenv:latest',
                description: 'docker image to use as devenv')
        string(name: 'NPM_REGISTRY', defaultValue: '',
                description: 'select alternative mirror if necessary, e.g. https://registry.npmjs.org/, http://r.cnpmjs.org/')
    }
    environment {
        PROJECT_SUBDIR = 'zigbee2mqtt'
        RESULT_SUBDIR = 'result'
    }
    stages {
        stage('Cleanup workspace') { steps {
            cleanWs deleteDirs: true, patterns: [[pattern: "$RESULT_SUBDIR", type: 'INCLUDE']]
        }}
        stage('Checkout') { steps { dir("$PROJECT_SUBDIR") {
            git branch: params.BRANCH, url: params.REPO
        }}}
        stage('Checkout tag') {
            when { expression {
                (params.TAG != "")
            }}
            steps { dir("$PROJECT_SUBDIR") {
                sshagent (credentials: ['jenkins-github-public-ssh']) {
                    sh 'git config --add remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" && git fetch --all'
                    sh "git checkout ${params.TAG}"
                }
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
                env.WB_VERSION_SUFFIX = wb.makeVersionSuffixFromBranch()
            }}
        }
        stage('Determine version') {
            steps { dir("$PROJECT_SUBDIR") { script {
                sshagent (credentials: ['jenkins-github-public-ssh']) {
                    sh 'git config --add remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" && git fetch --all'
                }
                env.PURE_VERSION = sh(returnStdout: true, script: "git describe --tags | sed -e 's/-.*//g'").trim()
                env.VERSION = env.PURE_VERSION + params.WB_REVISION + (env.WB_VERSION_SUFFIX ?: '')
                echo "Pure version: $PURE_VERSION"
                echo "Version with suffix: $VERSION"
            }}}
        }
        stage('Build') {
            environment {
                WBDEV_BUILD_METHOD="qemuchroot"
                WBDEV_TARGET="bullseye-armhf"
            }
            steps { script {
                def name = params.VERSION_TO_NAME ? "zigbee2mqtt-${PURE_VERSION}" : "zigbee2mqtt";
                def specialParams = "";
                if (params.VERSION_TO_NAME) {
                    specialParams = "--provides zigbee2mqtt --conflicts zigbee2mqtt --replaces zigbee2mqtt"
                }

                sh "printenv | sort"
                sh "wbdev root printenv | sort"
                sh "wbdev root bash -c 'ls -laR /usr/lib'"
                sh "wbdev chroot bash -c 'NPM_REGISTRY=${params.NPM_REGISTRY} ./build.sh ${name} ${VERSION} ${PROJECT_SUBDIR} ${RESULT_SUBDIR} ${specialParams}'"
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
        stage('Setup deploy') {
            when { expression {
                params.UPLOAD_TO_POOL
            }}
            steps { script {
                wbDeploy projectSubdir: env.PROJECT_SUBDIR,
                        forceOverwrite: params.FORCE_OVERWRITE,
                        filesFilter: "$RESULT_SUBDIR/*.deb",
                        withGithubRelease: false
            }}
        }
    }
}
