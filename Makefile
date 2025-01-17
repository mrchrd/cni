## Copyright 2018 Istio Authors
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##     http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.

#-----------------------------------------------------------------------------
# Global Variables
#-----------------------------------------------------------------------------
ISTIO_CNI_RELPATH ?= istio.io/cni

ISTIO_GO := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
export ISTIO_GO
SHELL := /bin/bash

# Current version, updated after a release.
VERSION ?= 0.1-dev

# cumulatively track the directories/files to delete after a clean
DIRS_TO_CLEAN:=
FILES_TO_CLEAN:=

# If GOPATH is not set by the env, set it to a sane value
GOPATH ?= $(shell cd ${ISTIO_GO}/../../..; pwd)
export GOPATH

# If GOPATH is made up of several paths, use the first one for our targets in this Makefile
GO_TOP := $(shell echo ${GOPATH} | cut -d ':' -f1)
export GO_TOP

# Note that disabling cgo here adversely affects go get.  Instead we'll rely on this
# to be handled in bin/gobuild.sh
# export CGO_ENABLED=0

# It's more concise to use GO?=$(shell which go)
# but the following approach uses a more efficient "simply expanded" :=
# variable instead of a "recursively expanded" =
ifeq ($(origin GO), undefined)
  GO:=$(shell which go)
endif
ifeq ($(GO),)
  $(error Could not find 'go' in path.  Please install go, or if already installed either add it to your path or set GO to point to its directory)
endif

LOCAL_ARCH := $(shell uname -m)
ifeq ($(LOCAL_ARCH),x86_64)
GOARCH_LOCAL := amd64
else
GOARCH_LOCAL := $(LOCAL_ARCH)
endif
export GOARCH ?= $(GOARCH_LOCAL)

LOCAL_OS := $(shell uname)
ifeq ($(LOCAL_OS),Linux)
   export GOOS_LOCAL = linux
else ifeq ($(LOCAL_OS),Darwin)
   export GOOS_LOCAL = darwin
else
   $(error "This system's OS $(LOCAL_OS) isn't recognized/supported")
   # export GOOS_LOCAL ?= windows
endif

export GOOS ?= $(GOOS_LOCAL)

export ENABLE_COREDUMP ?= false
#-----------------------------------------------------------------------------
# Output control
#-----------------------------------------------------------------------------
# Invoke make VERBOSE=1 to enable echoing of the command being executed
export VERBOSE ?= 0
# Place the variable Q in front of a command to control echoing of the command being executed.
Q = $(if $(filter 1,$VERBOSE),,@)
# Use the variable H to add a header (equivalent to =>) to informational output
H = $(shell printf "\033[34;1m=>\033[0m")

# To build with debugger information, use DEBUG=1 when invoking make
goVerStr := $(shell $(GO) version | awk '{split($$0,a," ")}; {print a[3]}')
goVerNum := $(shell echo $(goVerStr) | awk '{split($$0,a,"go")}; {print a[2]}')
goVerMajor := $(shell echo $(goVerNum) | awk '{split($$0, a, ".")}; {print a[1]}')
goVerMinor := $(shell echo $(goVerNum) | awk '{split($$0, a, ".")}; {print a[2]}')
gcflagsPattern := $(shell ( [ $(goVerMajor) -ge 1 ] && [ ${goVerMinor} -ge 10 ] ) && echo 'all=' || echo '')

ifeq ($(origin DEBUG), undefined)
BUILDTYPE_DIR:=release
else ifeq ($(DEBUG),0)
BUILDTYPE_DIR:=release
else
BUILDTYPE_DIR:=debug
export GCFLAGS:=$(gcflagsPattern)-N -l
$(info $(H) Build with debugger information)
endif

# Optional file including user-specific settings (HUB, TAG, etc)
-include .istiorc.mk

# @todo allow user to run for a single $PKG only?
PACKAGES_CMD := GOPATH=$(GOPATH) $(GO) list ./...
GO_EXCLUDE := /vendor/|.pb.go|.gen.go
GO_FILES_CMD := find . -name '*.go' | grep -v -E '$(GO_EXCLUDE)'

# Environment for tests, the directory containing istio and deps binaries.
# Typically same as GOPATH/bin, so tests work seemlessly with IDEs.

export ISTIO_BIN=$(GO_TOP)/bin
# Using same package structure as pkg/
export OUT_DIR=$(GO_TOP)/out
export ISTIO_OUT:=$(GO_TOP)/out/$(GOOS)_$(GOARCH)/$(BUILDTYPE_DIR)
export HELM=$(ISTIO_OUT)/helm

# scratch dir: this shouldn't be simply 'docker' since that's used for docker.save to store tar.gz files
ISTIO_DOCKER:=${ISTIO_OUT}/docker_temp

# scratch dir for building isolated images. Please don't remove it again - using
# ISTIO_DOCKER results in slowdown, all files (including multiple copies of envoy) will be
# copied to the docker temp container - even if you add only a tiny file, >1G of data will
# be copied, for each docker image.
DOCKER_BUILD_TOP:=${ISTIO_OUT}/docker_build

# dir where tar.gz files from docker.save are stored
ISTIO_DOCKER_TAR:=${ISTIO_OUT}/docker

GO_VERSION_REQUIRED:=1.9

HUB?=istio
ifeq ($(HUB),)
  $(error "HUB cannot be empty")
endif

# If tag not explicitly set in users' .istiorc.mk or command line, default to the git sha.
TAG ?= $(shell git rev-parse --verify HEAD)
ifeq ($(TAG),)
  $(error "TAG cannot be empty")
endif

# The point of these is to allow scripts to query where artifacts
# are stored so that tests and other consumers of the build don't
# need to be updated to follow the changes in the Makefiles.
# Note that the query needs to pass the same types of parameters
# (e.g., DEBUG=0, GOOS=linux) as the actual build for the query
# to provide an accurate result.
.PHONY: where-is-out where-is-docker-temp where-is-docker-tar
where-is-out:
	@echo ${ISTIO_OUT}
where-is-docker-temp:
	@echo ${ISTIO_DOCKER}
where-is-docker-tar:
	@echo ${ISTIO_DOCKER_TAR}

#-----------------------------------------------------------------------------
# Target: depend
#-----------------------------------------------------------------------------
.PHONY: depend depend.diff init

# Parse out the x.y or x.y.z version and output a single value x*10000+y*100+z (e.g., 1.9 is 10900)
# that allows the three components to be checked in a single comparison.
VER_TO_INT:=awk '{split(substr($$0, match ($$0, /[0-9\.]+/)), a, "."); print a[1]*10000+a[2]*100+a[3]}'

# using a sentinel file so this check is only performed once per version.  Performance is
# being favored over the unlikely situation that go gets downgraded to an older version
check-go-version: | $(ISTIO_BIN) ${ISTIO_BIN}/have_go_$(GO_VERSION_REQUIRED)
${ISTIO_BIN}/have_go_$(GO_VERSION_REQUIRED):
	@if test $(shell $(GO) version | $(VER_TO_INT) ) -lt \
                 $(shell echo "$(GO_VERSION_REQUIRED)" | $(VER_TO_INT) ); \
                 then printf "go version $(GO_VERSION_REQUIRED)+ required, found: "; $(GO) version; exit 1; fi
	@touch ${ISTIO_BIN}/have_go_$(GO_VERSION_REQUIRED)

# Ensure expected GOPATH setup
.PHONY: check-tree
check-tree:
	@if [ "$(ISTIO_GO)" != "$(GO_TOP)/src/$(ISTIO_CNI_RELPATH)" ]; then \
		echo Not building in expected path \'GOPATH/src/$(ISTIO_CNI_RELPATH)\'. Make sure to clone Istio into that path. Istio root=$(ISTIO_GO), GO_TOP=$(GO_TOP) ; \
		exit 1; fi

init: check-tree check-go-version
	mkdir -p ${OUT_DIR}/logs

# Pull dependencies, based on the checked in Gopkg.lock file.
# Developers must manually run `dep ensure` if adding new deps
depend: init | $(ISTIO_OUT)

$(ISTIO_OUT) $(ISTIO_BIN):
	@mkdir -p $@

#-----------------------------------------------------------------------------
# Target: precommit
#-----------------------------------------------------------------------------
.PHONY: precommit

# Target run by the pre-commit script, to automate formatting and lint
# If pre-commit script is not used, please run this manually.
precommit: fmt lint

#-----------------------------------------------------------------------------
# Target: go build
#-----------------------------------------------------------------------------

# gobuild script uses custom linker flag to set the variables.
# Params: OUT VERSION_PKG SRC

.PHONY: istio-cni
istio-cni ${ISTIO_OUT}/istio-cni:
	bin/gobuild.sh ${ISTIO_OUT}/istio-cni ./cmd/istio-cni

# Non-static istio-cnis. These are typically a build artifact.
${ISTIO_OUT}/istio-cni-linux: depend
	STATIC=0 GOOS=linux   bin/gobuild.sh $@ ./cmd/istio-cni

# Below is pattern for building for more platforms
#${ISTIO_OUT}/istio-cni-osx: depend
#	STATIC=0 GOOS=darwin  bin/gobuild.sh $@ ./cmd/istio-cni
#${ISTIO_OUT}/istio-cni-win.exe: depend
#	STATIC=0 GOOS=windows bin/gobuild.sh $@ ./cmd/istio-cni

.PHONY: build
# Build will rebuild the go binaries.
build: depend istio-cni

# istio-cni-all makes all of the non-static istio-cni executables for each supported OS
.PHONY: istio-cni-all
istio-cni-all: ${ISTIO_OUT}/istio-cni-linux
#istio-cni-all: ${ISTIO_OUT}/istio-cni-linux ${ISTIO_OUT}/istio-cni-osx ${ISTIO_OUT}/istio-cni-win.exe

# istio-cni-install builds then installs istio-cni into $GOPATH/BIN
# Used for debugging istio-cni during dev work
.PHONY: istio-cni-install
istio-cni-install:
	go install $(ISTIO_GO)/cmd/istio-cni

#-----------------------------------------------------------------------------
# Target: clean
#-----------------------------------------------------------------------------
.PHONY: clean clean.go

DIRS_TO_CLEAN+=${ISTIO_OUT}

clean: clean.go
	rm -rf $(DIRS_TO_CLEAN)
	rm -f $(FILES_TO_CLEAN)

clean.go: ; $(info $(H) cleaning...)
	$(eval GO_CLEAN_FLAGS := -i -r)
	$(Q) $(GO) clean $(GO_CLEAN_FLAGS)

#-----------------------------------------------------------------------------
# Target: docker
#-----------------------------------------------------------------------------

# for now docker is limited to Linux compiles - why ?
include tools/istio-cni-docker.mk


#-----------------------------------------------------------------------------
# Target: test
#-----------------------------------------------------------------------------
.PHONY: test

JUNIT_REPORT := $(shell which go-junit-report 2> /dev/null || echo "${ISTIO_BIN}/go-junit-report")

${ISTIO_BIN}/go-junit-report:
	@echo "go-junit-report not found. Installing it now..."
	unset GOOS && unset GOARCH && CGO_ENABLED=1 go get -u github.com/jstemmer/go-junit-report

# Run coverage tests
JUNIT_UNIT_TEST_XML ?= $(ISTIO_OUT)/junit_unit-tests.xml
ifeq ($(WHAT),)
       TEST_OBJ = install-test cmd-test
else
       TEST_OBJ = selected-pkg-test
endif
test: | $(JUNIT_REPORT)
	mkdir -p $(dir $(JUNIT_UNIT_TEST_XML))
	set -o pipefail; \
	$(MAKE) --keep-going $(TEST_OBJ) \
	2>&1 | tee >($(JUNIT_REPORT) > $(JUNIT_UNIT_TEST_XML))

.PHONY: install-test
# May want to make this depend on push but it will always push at the moment:  install-test: docker.push
install-test:
	HUB=${HUB} TAG=${TAG} go test -v ${T} ./test/...

.PHONY: selected-pkg-test
selected-pkg-test:
	find ${WHAT} -name "*_test.go"|xargs -i dirname {}|uniq|xargs -i go test ${T} {}

.PHONY: cmd-test
cmd-test:
	go test ./cmd/...

lint:
	@scripts/check_license.sh
	@scripts/run_golangci.sh

fmt:
	@scripts/run_gofmt.sh

include Makefile.common.mk
