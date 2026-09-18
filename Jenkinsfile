// FIXME: generalize this pipeline some day for other 3rdparties

// One way to build per target, so it follows from the architecture instead of a parameter.
// ARM: inside the controller rootfs, everything native is compiled under qemu.
// amd64: devenv has no amd64 rootfs, the devenv container itself is trixie amd64, so it builds there
String wbdevCommand() {
    if (params.WBDEV_TARGET.endsWith('-amd64')) {
        return 'root'
    }
    return 'chroot'
}

// The popup of a stage in Stage View shows the message of the error that stopped it, and a failed
// sh step writes there "script returned exit code N". Every script lists its codes in its own
// header, so the message says what the code means instead of leaving the log the only place to look
String exitMeaning(String script, int code) {
    String codes = ''
    for (String line in readFile("scripts/${script}").split('\n')) {
        if (line.startsWith('# Exit:')) {
            codes = line.replaceFirst(/# Exit:\s*/, '')
            continue
        }
        // The list may go on over the next lines, each of them indented and starting with a code
        if (codes && line ==~ /^#\s\s+\d+ .*/) {
            codes += ' ' + line.replaceFirst(/^#\s+/, '')
            continue
        }
        if (codes) {
            break
        }
    }
    for (String item in codes.split(',')) {
        String entry = item.trim()
        int space = entry.indexOf(' ')
        if (space > 0 && entry.substring(0, space) == code.toString()) {
            return entry.substring(space + 1)
        }
    }
    return 'the header of the script does not list this code'
}

// Runs one of scripts/ where this target is built, with the variables that script reads.
// bash runs it, so a checkout without the executable bit still works
void runScript(String script, String variables, String args) {
    int rc = sh(returnStatus: true, script: "wbdev ${wbdevCommand()} bash -c " +
                "\"${variables} bash scripts/${script} ${args}\"")
    if (rc != 0) {
        error("scripts/${script} stopped with code ${rc}: ${exitMeaning(script, rc)}")
    }
}

// Where the package belongs. Controllers take theirs from the release repository, amd64 is built
// for development machines and goes to dev-tools. Each repository has its own testing sets, named
// by its own config: a set published with the release config serves armhf and arm64, a set that
// has to serve amd64 lives in dev-tools. wb.repos gives the upload job and the aptly config
Map targetRepo() {
    if (params.WBDEV_TARGET.endsWith('-amd64')) {
        return [name:              'dev-tools',
                uploadJob:         wb.repos.devTools.uploadJob,
                aptlyConfig:       wb.repos.devTools.aptlyConfig,
                testingSetsConfig: 'testing-sets-devtools-aptly-config']
    }
    return [name:              'release',
            uploadJob:         wb.repos.release.uploadJob,
            aptlyConfig:       wb.repos.release.aptlyConfig,
            testingSetsConfig: 'testing-sets-release-aptly-config']
}

// The devenv image of the target release, unless the parameter names another one
String devenvImage() {
    if (params.WBDEV_IMAGE) {
        return params.WBDEV_IMAGE
    }
    if (params.WBDEV_TARGET.startsWith('bullseye')) {
        return 'contactless/devenv:latest_bullseye'
    }
    return 'contactless/devenv:latest'
}

// devenv reads this as a flag: a non-empty value adds the unstable repository below the stable one
String unstableDeps() {
    if (params.USE_TESTING_REPOSITORY) {
        return 'y'
    }
    return ''
}

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
        choice(name: 'WBDEV_TARGET',
                choices: ['trixie-armhf', 'trixie-arm64', 'trixie-amd64', 'bullseye-armhf', 'bullseye-arm64'],
                description: '''Target architecture. The controller ones are built in their rootfs under qemu; trixie-amd64 is built natively in the devenv container itself and goes to the dev-tools repository, for development machines. Its Node.js comes from dev-tools too: nothing else is in the container sources, so WBDEV_TESTING_SETS does not reach this build. A set that has to serve amd64 is a dev-tools set, published with testing-sets-devtools-aptly-config''')
        choice(name: 'BUILD_AND_REQUIRE_NODEJS',
                choices: ['24', '22', '16'],
                description: '''The package is built on this Node.js major and pinned to it: scripts/build.sh turns 24 into nodejs (>= 24), nodejs (<< 25), so the package refuses to install on another major. The reason is unix-dgram, a native module built for the ABI of that Node.js:
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

        // The place the build runs, shared by Build and Test deb: the package is checked on the
        // very Node.js it was built with
        WBDEV_BUILD_METHOD = "qemuchroot"
        WBDEV_USE_UNSTABLE_DEPS = "${unstableDeps()}"
        // Initialize params as envvars, workaround for bug https://issues.jenkins-ci.org/browse/JENKINS-41929
        WBDEV_IMAGE = "${devenvImage()}"
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

                if (params.WBDEV_TARGET.startsWith('bullseye') && params.BUILD_AND_REQUIRE_NODEJS.toInteger() >= 24) {
                    error("BUILD_AND_REQUIRE_NODEJS=${params.BUILD_AND_REQUIRE_NODEJS} for ${params.WBDEV_TARGET}: Node.js 24 needs glibc 2.38, bullseye has 2.31")
                }

                def repoType = "stable"
                if (params.USE_TESTING_REPOSITORY) {
                    repoType = "testing"
                }
                def buildName = "#${BUILD_NUMBER}:${params.WBDEV_TARGET}/${repoType}"
                if (params.TAG) {
                    buildName += " custom_tag=${params.TAG}"
                }
                def description = "Build on Node.js ${params.BUILD_AND_REQUIRE_NODEJS} for ${params.WBDEV_TARGET}"
                // Such a package stays out of the regular repositories: an ~exp~ version reaches a
                // testing set and nothing else. Staging drops those, unstable follows staging
                def exp = params.ADD_VERSION_SUFFIX && !wb.isBranchRelease(env.BRANCH_NAME)
                def repo = targetRepo()
                if (params.UPLOAD_TO_POOL) {
                    description += ", uploads to ${repo.name} (${repo.uploadJob})"
                    if (exp) {
                        description += ", ~exp~ goes to a set of ${repo.testingSetsConfig}"
                    }
                } else {
                    description += ", no upload"
                }

                def testingSets = params.WBDEV_TESTING_SETS.trim()
                if (testingSets) {
                    if (params.UPLOAD_TO_POOL && !exp) {
                        error("UPLOAD_TO_POOL with WBDEV_TESTING_SETS needs an ~exp~ version: " +
                              "ADD_VERSION_SUFFIX on a non-release branch.")
                    }
                    // This parameter is about taking packages from a set, and wbdev does that by
                    // writing the set into the rootfs. An amd64 build never enters one: it runs in the
                    // devenv container, whose apt sources are fixed in the image. Publishing into a set
                    // is the other direction and works for amd64, with the dev-tools config
                    if (wbdevCommand() == 'root') {
                        error("WBDEV_TESTING_SETS for ${params.WBDEV_TARGET}: wbdev adds a set to the " +
                              "rootfs, and this target is built in the devenv container instead, which " +
                              "takes packages from dev-tools only. The Node.js this build needs has to " +
                              "be in dev-tools itself.")
                    }
                    // devenv checks the names itself; images without PR #284 ignore the sets in wbdev chroot
                    if (params.WBDEV_TARGET.startsWith('bullseye') && !params.WBDEV_IMAGE) {
                        error("WBDEV_TESTING_SETS: contactless/devenv:latest_bullseye used for ${params.WBDEV_TARGET} does not add testing sets in wbdev chroot")
                    }
                    buildName += " testing_sets=${testingSets}"
                    description += ", builds on testing sets: ${testingSets}"
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
                        def tagToUse = params.TAG
                        if (!tagToUse) {
                            tagToUse = env.LATEST_TAG
                        }
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
                // The suffix stage runs for branches only, so a release build has nothing to add here
                def suffix = ''
                if (env.WB_VERSION_SUFFIX) {
                    suffix = env.WB_VERSION_SUFFIX
                }
                env.VERSION = env.PURE_VERSION + params.WB_REVISION + suffix
                echo "Pure version: $PURE_VERSION"
                echo "Version with suffix: $VERSION"
            }}}
        }
        stage('Build') {
            steps { script {
                def name = "zigbee2mqtt"
                def specialParams = ""
                if (params.VERSION_TO_NAME) {
                    name = "zigbee2mqtt-${PURE_VERSION}"
                    specialParams = "--provides zigbee2mqtt --conflicts zigbee2mqtt --replaces zigbee2mqtt"
                }

                sh "printenv | sort"
                sh "wbdev root printenv | sort"
                runScript('build.sh',
                          "BUILD_AND_REQUIRE_NODEJS='${params.BUILD_AND_REQUIRE_NODEJS}' " +
                          "NPM_REGISTRY='${params.NPM_REGISTRY}'",
                          "${name} ${VERSION} ${PROJECT_SUBDIR} ${RESULT_SUBDIR} ${specialParams}")
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
        // Nothing leaves the build unchecked: the package is opened where it was built, and its
        // native modules are loaded on the Node.js it declares
        stage('Test deb') {
            steps {
                runScript('test-deb.sh',
                          "BUILD_AND_REQUIRE_NODEJS='${params.BUILD_AND_REQUIRE_NODEJS}'",
                          "${RESULT_SUBDIR}")
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
                        uploadJob: targetRepo().uploadJob,
                        aptlyConfig: targetRepo().aptlyConfig,
                        forceOverwrite: params.FORCE_OVERWRITE,
                        withGithubRelease: false
            }}
        }
    }
}
