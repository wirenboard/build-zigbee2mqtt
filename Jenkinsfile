// FIXME: generalize this pipeline some day for other 3rdparties

// A push or a repository scan checks only what can be checked without Node.js of the required
// major: the pipeline parses, the tag resolves, the version is computed, the pool is looked at.
// Building needs that Node.js in the rootfs, and until it is in the repositories it comes from a
// testing set, which is a parameter of a build started by hand. Named as in wb-nodejs-packaging
boolean fullRun() {
    return currentBuild.getBuildCauses('jenkins.branch.BranchEventCause').isEmpty() &&
           currentBuild.getBuildCauses('jenkins.branch.BranchIndexingCause').isEmpty()
}

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
    return 'not a code of the script: under set -e the code of the command that failed goes out as it is'
}

// The version helpers below are those of wb-nodejs-packaging, with zigbee2mqtt in place of Node.js

// changelogField <name>: a field of the entry on top of debian/changelog, Version or Distribution.
// dpkg-parsechangelog reads the file the way the package build does; it lives in the wbdev
// container, because the agent has no dpkg-dev, and the container takes about a second to start
String changelogField(String name) {
    return sh(returnStdout: true, script: "wbdev user dpkg-parsechangelog -S ${name}").trim()
}

// The package version lives in debian/changelog and only there: zigbee2mqtt (2.14.1-wb102) stable; ...
// The answer is kept in the environment, so the container starts once. A stage restarted on its
// own starts with an empty environment and asks again; the checkout gives the same answer. On a
// branch build the entry already carries the suffix by then, and the base version is what is left
String baseVersion() {
    if (env.WB_BASE_VERSION) {
        return env.WB_BASE_VERSION
    }
    def parsed = changelogField('Version')
    if (!(parsed ==~ /\d+\.\d+\.\d+-wb\d+(~\S+)?/)) {
        error("debian/changelog names the version '${parsed}', expected '<zigbee2mqtt tag>-wb<N>'")
    }
    env.WB_BASE_VERSION = parsed.replaceFirst(/~.*$/, '')
    return env.WB_BASE_VERSION
}

// The upstream tag this package is built from: 2.14.1-wb102 builds the tag 2.14.1
String upstreamVersion() {
    return baseVersion().replaceFirst(/-wb\d+$/, '')
}

// Computed once in 'Determine version suffix'. A stage restarted on its own starts with an empty
// env, so it is computed again here; the answer depends only on the checkout and the branch
String versionSuffix() {
    if (env.WB_VERSION_SUFFIX != null) {
        return env.WB_VERSION_SUFFIX
    }
    if (!params.ADD_VERSION_SUFFIX || wb.isBranchRelease(env.BRANCH_NAME)) {
        return ''
    }
    def suffix = wb.makeVersionSuffixFromBranch(wb.getMainBranchName())
    if (!suffix) {
        return ''
    }
    return suffix
}

// 'Determine version' writes this version into debian/changelog, and fpm packs that file as the
// changelog of the package, so the entry on top and the Version field always agree
String version() {
    if (env.PKG_VERSION) {
        return env.PKG_VERSION
    }
    return baseVersion() + versionSuffix()
}

// The entry wb.addVersionSuffix() writes for library jobs, with two differences: the distribution
// of the previous entry is kept, because dch writes UNRELEASED otherwise, and the values reach the
// command line through the environment and a file, so quotes in a commit message or in a name
// cannot break it
void writeChangelogEntry(String pkgVersion) {
    // A stage restarted on its own meets the entry its first run wrote
    if (changelogField('Version') == pkgVersion) {
        echo "debian/changelog already carries ${pkgVersion}, no second entry is written"
        return
    }
    writeFile file: 'changelog-entry.tmp',
              text: '(Version is generated automatically by CI/CD)\n' + wb.getGitCommitMessage()
    withEnv(["DCH_NAME=${wb.getGitCommitAuthor()}",
             "DCH_EMAIL=${wb.getGitCommitAuthorEmail()}",
             "DCH_VERSION=${pkgVersion}",
             "DCH_DIST=${changelogField('Distribution')}"]) {
        // -b: the branch version sorts below the one already in the changelog, and dch stops on that
        sh 'wbdev user env DEBFULLNAME="$DCH_NAME" DEBEMAIL="$DCH_EMAIL" ' +
           'dch --newversion "$DCH_VERSION" --distribution "$DCH_DIST" ' +
           '--force-distribution -b "$(cat changelog-entry.tmp)"'
    }
    sh 'rm -f changelog-entry.tmp'
    echo "debian/changelog of this build: the entry on top is the one just written, and this\n" +
         "is what the package will carry.\n\n" + readFile('debian/changelog')
}

// The name of the package built here: with VERSION_TO_NAME the version goes into the name, for
// an old release kept beside the current one. Computed like version(), so a stage restarted on
// its own gets the same answer instead of an empty environment variable
String packageName() {
    if (params.VERSION_TO_NAME) {
        return "zigbee2mqtt-${upstreamVersion()}"
    }
    return 'zigbee2mqtt'
}

// The arguments of build.sh, the same for both of its steps
String buildArguments() {
    String special = params.VERSION_TO_NAME
        ? "--provides zigbee2mqtt --conflicts zigbee2mqtt --replaces zigbee2mqtt" : ""
    return "${packageName()} ${version()} ${env.PROJECT_SUBDIR} ${env.RESULT_SUBDIR} ${special}"
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

// The versions of this package for this architecture that are in the pool now, oldest first:
// the pool is a public bucket, so a build can look into it before it spends an hour compiling.
// Why this is checked at all: Jenkins-guide.md, "FORCE_OVERWRITE"
List poolVersions(String poolPrefix, String pkg, String arch) {
    String suffix = "_${arch}.deb"
    String bucket = 'https://s3-eu-west-1.amazonaws.com/deb.wirenboard.com'
    // In two steps on purpose: in one pipeline the exit code would be the one of sort, and a
    // failed request would read as an empty pool, which is the answer that lets an upload through
    sh "curl -sS --fail --max-time 60 '${bucket}?list-type=2" +
       "&prefix=${poolPrefix}/pool/main/${pkg[0]}/${pkg}/' -o pool-listing.xml"
    if (!readFile('pool-listing.xml').contains('ListBucketResult')) {
        error("the answer of ${bucket} is not a listing of the pool, see pool-listing.xml")
    }
    String listing = sh(returnStdout: true, script:
        "grep -oE '<Key>[^<]+' pool-listing.xml | sed 's|.*/||' | sort -V || true").trim()
    sh 'rm -f pool-listing.xml'

    // The bucket holds a twin of every ~exp~ upload, with the pluses of the version turned
    // into spaces: same size, same content, another key. One of the two is enough here
    return listing.split('\n')
        .findAll { it.startsWith("${pkg}_") && it.endsWith(suffix) && !it.contains(' ') }
        .collect { it[(pkg.length() + 1)..-(suffix.length() + 1)] }
        .unique()
}

// Where the package belongs: controllers take theirs from the release repository, amd64 goes to
// dev-tools. Each repository has its own testing sets, with its own aptly config, and wb.repos
// gives the upload job. Which and why: Jenkins-guide.md, "WBDEV_TARGET"
Map targetRepo() {
    if (params.WBDEV_TARGET.endsWith('-amd64')) {
        return [name:              'dev-tools',
                uploadJob:         wb.repos.devTools.uploadJob,
                aptlyConfig:       wb.repos.devTools.aptlyConfig,
                testingSetsConfig: 'testing-sets-devtools-aptly-config',
                poolPrefix:        'dev-tools']
    }
    return [name:              'release',
            uploadJob:         wb.repos.release.uploadJob,
            aptlyConfig:       wb.repos.release.aptlyConfig,
            testingSetsConfig: 'testing-sets-release-aptly-config',
            poolPrefix:        'all']
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
        // Not an input: a note in the form, as in wb-nodejs-packaging
        choice(name: 'PACKAGE_VERSION', choices: ['set in debian/changelog, not here'],
                description: '''The top entry of debian/changelog on this branch names both the zigbee2mqtt tag to build and the Wiren Board revision. To build another version, add an entry there in a branch: Jenkins-guide.md, "Общие сведения"''')

        string(name: 'REPO', defaultValue: 'https://github.com/Koenkk/zigbee2mqtt', description: 'Repo to get zigbee2mqtt from')
        string(name: 'BRANCH', defaultValue: 'master', description: 'For checkout step')
        booleanParam(name: 'VERSION_TO_NAME', defaultValue: false, description: 'Adds version number to package name as suffix, creating names like zigbee2mqtt-1.18.1')
        booleanParam(name: 'ADD_VERSION_SUFFIX', defaultValue: true, description: 'For dev branches only')
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

        // The place the build runs. Test .deb uses the same method, so the package is checked on a
        // rootfs of the same kind, with the Node.js of the same version installed anew by apt
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
                // A build started with the parameters of the old job, by a saved trigger or by
                // "Rebuild", would carry a version nobody reads any more
                if (params.PACKAGE_VERSION && !params.PACKAGE_VERSION.contains('debian/changelog')) {
                    error("PACKAGE_VERSION='${params.PACKAGE_VERSION}': the version is not a parameter, it is the top entry " +
                          "of debian/changelog on this branch (${baseVersion()}). See Jenkins-guide.md.")
                }
                if (params.TAG || params.WB_REVISION) {
                    error("TAG and WB_REVISION are gone: the tag to build and the revision both come from the top entry " +
                          "of debian/changelog on this branch (${baseVersion()}). See Jenkins-guide.md.")
                }

                // These values go into shell command lines: allow only what they legitimately contain
                def formats = [
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
                def kind = 'checks only'
                if (fullRun()) {
                    kind = 'full'
                }
                def buildName = "#${BUILD_NUMBER}: ${baseVersion()}/${params.WBDEV_TARGET}/${repoType} [${kind}]"
                def description = "Build on Node.js ${params.BUILD_AND_REQUIRE_NODEJS} for ${params.WBDEV_TARGET}"
                if (!fullRun()) {
                    description = "Checks only, started by a push or a repository scan: the package " +
                                  "itself is built by a run started by hand. " + description
                }
                // Such a package stays out of the regular repositories: an ~exp~ version reaches a
                // testing set and nothing else. Staging drops those, unstable follows staging
                def exp = params.ADD_VERSION_SUFFIX && !wb.isBranchRelease(env.BRANCH_NAME)
                // A non-release branch reaches the pool only with the branch suffix: an ~exp~ version for testing sets
                if (params.UPLOAD_TO_POOL && !wb.isBranchRelease(env.BRANCH_NAME) && !params.ADD_VERSION_SUFFIX) {
                    error("UPLOAD_TO_POOL on '${env.BRANCH_NAME}', which is not a release branch, needs ADD_VERSION_SUFFIX: " +
                          "without the branch suffix the version stays ${baseVersion()} and passes for a release.")
                }
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
        // The upstream tag is named by debian/changelog, see baseVersion()
        stage('Checkout tag') {
            steps { script {
              // Before dir(): a restarted stage reads debian/changelog again, and it is in the root
              String tag = upstreamVersion()
              dir("$PROJECT_SUBDIR") {
                sshagent (credentials: ['jenkins-github-public-ssh']) {
                    sh 'git config --add remote.origin.fetch "+refs/tags/*:refs/tags/*" && git fetch --all'
                    echo "Checking out tag: ${tag}"
                    sh "git checkout ${tag}"
                }
                sh 'git clean -xdf'

                // FIXME: this output need for catch bug when result
                //        deb package increase to x2, for example
                //        normal sise is 27mb, but generate 54mb.
                //        in big packet we can find pnpm pakages dublicates
                echo "File list before build start:"
                sh "ls -lahR --color=auto"
              }
            }}
        }
        // Named as in wb-nodejs-packaging and in the jenkins-pipeline-lib jobs: the suffix of a
        // branch build is decided in one place, and a release build shows the stage as skipped
        stage('Determine version suffix') {
            when { expression {
                params.ADD_VERSION_SUFFIX && !wb.isBranchRelease(env.BRANCH_NAME)
            }}
            steps { script {
                sshagent (credentials: ['jenkins-github-public-ssh']) {
                    sh 'git config --add remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" && git fetch --all'
                }
                env.WB_VERSION_SUFFIX = versionSuffix()
                echo "Version suffix: ${env.WB_VERSION_SUFFIX}"
            }}
        }
        // The version of this build, and the changelog entry that carries it into the package
        stage('Determine version') {
            steps { script {
                env.PKG_VERSION = baseVersion() + versionSuffix()
                echo "Base version from debian/changelog: ${baseVersion()}"
                echo "Version of this build: ${env.PKG_VERSION}"
                if (env.PKG_VERSION != baseVersion()) {
                    writeChangelogEntry(env.PKG_VERSION)
                }
                echo "Package name: ${packageName()}"
            }}
        }
        // What the pool has now, and what this build would do to it. Before the long part, because
        // an upload that silently changes nothing is worth knowing about before the build, not after
        stage('Check the version in the pool') {
            steps { script {
                Map repo = targetRepo()
                String arch = params.WBDEV_TARGET.tokenize('-').last()
                List versions = poolVersions(repo.poolPrefix, packageName(), arch)

                if (versions.isEmpty()) {
                    echo "Pool of ${repo.name}: no ${packageName()} for ${arch} there yet"
                } else {
                    // The whole list, so the log keeps what the pool held at the time of this build
                    echo "Pool of ${repo.name}, ${versions.size()} ${packageName()} ${arch} package(s):\n  " +
                         versions.join('\n  ')
                    echo "Newest in the pool: ${versions.last()}"
                }

                boolean inPool = versions.contains(env.PKG_VERSION)
                if (!inPool && params.UPLOAD_TO_POOL) {
                    echo "${env.PKG_VERSION} is not there: this build adds it"
                } else if (!inPool) {
                    echo "${env.PKG_VERSION} is not there, and this build does not upload"
                } else if (!params.UPLOAD_TO_POOL) {
                    echo "${env.PKG_VERSION} is already there; this build does not upload, so it stays as it is"
                } else if (params.FORCE_OVERWRITE) {
                    echo "${env.PKG_VERSION} is already there and FORCE_OVERWRITE is on: " +
                         "this build replaces the package in the pool"
                } else {
                    error("${env.PKG_VERSION} is already in the pool of ${repo.name}. wbci-repo keeps the " +
                          "package it already has and skips the new one, so this build would upload " +
                          "nothing: add an entry to debian/changelog, or set FORCE_OVERWRITE to replace it.")
                }
            }}
        }
        stage('Build') {
            when { expression { fullRun() } }
            steps { script {
                sh "printenv | sort"
                sh "wbdev root printenv | sort"
                runScript('build.sh',
                          "BUILD_AND_REQUIRE_NODEJS='${params.BUILD_AND_REQUIRE_NODEJS}' " +
                          "NPM_REGISTRY='${params.NPM_REGISTRY}'",
                          "--step build ${buildArguments()}")
            }}
            post {
                always {
                    sh 'wbdev root chown -R jenkins:jenkins .'
                }
            }
        }

        // For now only what nobody can use on a controller at all: the test suite, which has no
        // vitest to run it there, and the state of an incremental TypeScript compile. The script
        // names the candidates for later. build.sh asks it with --check before it packs
        stage('Remove files a controller cannot use') {
            when { expression { fullRun() } }
            steps {
                runScript('prune-files.sh', "", "${PROJECT_SUBDIR}")
            }
            post {
                always {
                    sh 'wbdev root chown -R jenkins:jenkins .'
                }
            }
        }

        stage('Pack .deb') {
            when { expression { fullRun() } }
            steps { script {
                runScript('build.sh',
                          "BUILD_AND_REQUIRE_NODEJS='${params.BUILD_AND_REQUIRE_NODEJS}' " +
                          "NPM_REGISTRY='${params.NPM_REGISTRY}'",
                          "--step pack ${buildArguments()}")
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
        stage('Test .deb') {
            when { expression { fullRun() } }
            steps {
                runScript('test-deb.sh',
                          "BUILD_AND_REQUIRE_NODEJS='${params.BUILD_AND_REQUIRE_NODEJS}'",
                          "${RESULT_SUBDIR}")
            }
            post {
                always {
                    sh 'wbdev root chown -R jenkins:jenkins .'
                    // The counts land on the job page, so the result of the checks is visible
                    // without opening the log of the stage
                    script {
                        String summary = "${RESULT_SUBDIR}/test-summary.txt"
                        if (fileExists(summary)) {
                            currentBuild.description += " | tests: ${readFile(summary).trim()}"
                        }
                    }
                }
            }
        }
        // wbDeploy uploads every archived .deb of this build, which is why only result/*.deb is archived
        stage('Upload .deb to apt pool') {
            when { expression {
                fullRun() && params.UPLOAD_TO_POOL
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
