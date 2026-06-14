# Build:    VERSION=v0.1.12 make container-csi
# Sideload: VERSION=v0.1.12 make sideload-csi
# Runtime:  VERSION=v0.1.13 make sideload-runtime
#
# Sideload ONLY — the in-cluster registry is backed by SeaweedFS itself,
# so pushing would be a chicken-and-egg dep. See
# memory/feedback_always_sideload_seaweedfs_images.md.
.PHONY: FORCE build container container-csi container-mount container-recycler \
        push push-csi push-mount push-recycler \
        tars-csi tars-mount tars-recycler tars-runtime \
        sideload-csi sideload-csi-amd64 sideload-csi-arm64 \
        sideload-mount sideload-mount-amd64 sideload-mount-arm64 \
        sideload-recycler sideload-recycler-amd64 sideload-recycler-arm64 \
        sideload-runtime \
        verify-csi verify-mount verify-recycler verify-runtime \
        clean deps

REGISTRY_NAME ?= registry.brmartin.co.uk/ben
DRIVER_IMAGE_NAME ?= seaweedfs-csi-driver
MOUNT_IMAGE_NAME ?= seaweedfs-mount
RECYCLER_IMAGE_NAME ?= seaweedfs-consumer-recycler
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD)
SEAWEEDFS_SOURCE ?= /home/ben/Documents/Personal/projects/seaweedfs
SEAWEEDFS_COMMIT ?= $(shell git -C $(SEAWEEDFS_SOURCE) rev-parse --short HEAD)
LDFLAGS ?= -s -w -X github.com/seaweedfs/seaweedfs-csi-driver/pkg/driver.gitCommit=${COMMIT}

OUTPUT_DIR := _output
DRIVER_BINARY := $(OUTPUT_DIR)/seaweedfs-csi-driver
MOUNT_BINARY := $(OUTPUT_DIR)/seaweedfs-mount
RECYCLER_BINARY := $(OUTPUT_DIR)/seaweedfs-consumer-recycler
MOUNT_WEED_AMD64_BINARY := $(OUTPUT_DIR)/weed-amd64
MOUNT_WEED_ARM64_BINARY := $(OUTPUT_DIR)/weed-arm64
MOUNT_WRAPPER_AMD64_BINARY := $(OUTPUT_DIR)/seaweedfs-mount-amd64
MOUNT_WRAPPER_ARM64_BINARY := $(OUTPUT_DIR)/seaweedfs-mount-arm64
MOUNT_AMD64_CONTEXT := $(OUTPUT_DIR)/mount-image-amd64
MOUNT_ARM64_CONTEXT := $(OUTPUT_DIR)/mount-image-arm64

DRIVER_IMAGE_TAG := $(REGISTRY_NAME)/$(DRIVER_IMAGE_NAME):$(VERSION)
MOUNT_IMAGE_TAG := $(REGISTRY_NAME)/$(MOUNT_IMAGE_NAME):$(VERSION)
RECYCLER_IMAGE_TAG := $(REGISTRY_NAME)/$(RECYCLER_IMAGE_NAME):$(VERSION)

# Tars for sideloading the csi-driver image to k3s nodes.
DRIVER_AMD64_TAR := $(OUTPUT_DIR)/$(DRIVER_IMAGE_NAME)-$(VERSION)-amd64.tar
DRIVER_ARM64_TAR := $(OUTPUT_DIR)/$(DRIVER_IMAGE_NAME)-$(VERSION)-arm64.tar
MOUNT_AMD64_TAR := $(OUTPUT_DIR)/$(MOUNT_IMAGE_NAME)-$(VERSION)-amd64.tar
MOUNT_ARM64_TAR := $(OUTPUT_DIR)/$(MOUNT_IMAGE_NAME)-$(VERSION)-arm64.tar
RECYCLER_AMD64_TAR := $(OUTPUT_DIR)/$(RECYCLER_IMAGE_NAME)-$(VERSION)-amd64.tar
RECYCLER_ARM64_TAR := $(OUTPUT_DIR)/$(RECYCLER_IMAGE_NAME)-$(VERSION)-arm64.tar

AMD64_NODES ?= hestia.lan
ARM64_NODES ?= heracles.lan nyx.lan
SSH ?= ssh
SCP ?= scp

deps:
	go mod tidy

FORCE:

build: $(DRIVER_BINARY) $(MOUNT_BINARY) $(RECYCLER_BINARY)

$(OUTPUT_DIR):
	mkdir -p $@

$(DRIVER_BINARY): FORCE | $(OUTPUT_DIR)
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '$(LDFLAGS)' -o $@ ./cmd/seaweedfs-csi-driver/main.go

$(MOUNT_BINARY): FORCE | $(OUTPUT_DIR)
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '$(LDFLAGS)' -o $@ ./cmd/seaweedfs-mount/main.go

$(MOUNT_WEED_AMD64_BINARY): FORCE | $(OUTPUT_DIR)
	cd $(SEAWEEDFS_SOURCE) && \
	  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build \
	    -ldflags "-X github.com/seaweedfs/seaweedfs/weed/util/version.COMMIT=$(SEAWEEDFS_COMMIT)" \
	    -o $(abspath $@) ./weed

$(MOUNT_WEED_ARM64_BINARY): FORCE | $(OUTPUT_DIR)
	cd $(SEAWEEDFS_SOURCE) && \
	  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
	    -ldflags "-X github.com/seaweedfs/seaweedfs/weed/util/version.COMMIT=$(SEAWEEDFS_COMMIT)" \
	    -o $(abspath $@) ./weed

$(MOUNT_WRAPPER_AMD64_BINARY): FORCE | $(OUTPUT_DIR)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags '$(LDFLAGS)' -o $@ ./cmd/seaweedfs-mount/main.go

$(MOUNT_WRAPPER_ARM64_BINARY): FORCE | $(OUTPUT_DIR)
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags '$(LDFLAGS)' -o $@ ./cmd/seaweedfs-mount/main.go

$(MOUNT_AMD64_CONTEXT): $(MOUNT_WEED_AMD64_BINARY) $(MOUNT_WRAPPER_AMD64_BINARY)
	rm -rf $@
	mkdir -p $@
	cp $(MOUNT_WEED_AMD64_BINARY) $@/weed
	cp $(MOUNT_WRAPPER_AMD64_BINARY) $@/seaweedfs-mount

$(MOUNT_ARM64_CONTEXT): $(MOUNT_WEED_ARM64_BINARY) $(MOUNT_WRAPPER_ARM64_BINARY)
	rm -rf $@
	mkdir -p $@
	cp $(MOUNT_WEED_ARM64_BINARY) $@/weed
	cp $(MOUNT_WRAPPER_ARM64_BINARY) $@/seaweedfs-mount

$(RECYCLER_BINARY): FORCE | $(OUTPUT_DIR)
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '$(LDFLAGS)' -o $@ ./cmd/seaweedfs-consumer-recycler/

container: container-csi container-mount container-recycler

container-csi: $(DRIVER_BINARY)
	docker build -t $(DRIVER_IMAGE_TAG) -f cmd/seaweedfs-csi-driver/Dockerfile.dev .

container-mount: $(MOUNT_BINARY)
	docker buildx build \
	  --build-context seaweedfs=$(SEAWEEDFS_SOURCE) \
	  --build-arg SEAWEEDFS_COMMIT=$(SEAWEEDFS_COMMIT) \
	  --load \
	  -t $(MOUNT_IMAGE_TAG) \
	  -f cmd/seaweedfs-mount/Dockerfile .

container-recycler:
	docker build -t $(RECYCLER_IMAGE_TAG) -f cmd/seaweedfs-consumer-recycler/Dockerfile .

push: push-csi push-mount push-recycler

push-csi: container-csi
	docker push $(DRIVER_IMAGE_TAG)

push-mount: container-mount
	docker push $(MOUNT_IMAGE_TAG)

push-recycler: container-recycler
	docker push $(RECYCLER_IMAGE_TAG)

tars-csi: $(DRIVER_AMD64_TAR) $(DRIVER_ARM64_TAR)
tars-mount: $(MOUNT_AMD64_TAR) $(MOUNT_ARM64_TAR)
tars-recycler: $(RECYCLER_AMD64_TAR) $(RECYCLER_ARM64_TAR)
tars-runtime: tars-mount tars-recycler

$(DRIVER_AMD64_TAR): cmd/seaweedfs-csi-driver/Dockerfile | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/amd64 \
	  -t $(DRIVER_IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f cmd/seaweedfs-csi-driver/Dockerfile .

$(DRIVER_ARM64_TAR): cmd/seaweedfs-csi-driver/Dockerfile | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/arm64 \
	  -t $(DRIVER_IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f cmd/seaweedfs-csi-driver/Dockerfile .

$(MOUNT_AMD64_TAR): cmd/seaweedfs-mount/Dockerfile.prebuilt $(MOUNT_AMD64_CONTEXT) | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/amd64 \
	  -t $(MOUNT_IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f cmd/seaweedfs-mount/Dockerfile.prebuilt \
	  $(MOUNT_AMD64_CONTEXT)

$(MOUNT_ARM64_TAR): cmd/seaweedfs-mount/Dockerfile.prebuilt $(MOUNT_ARM64_CONTEXT) | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/arm64 \
	  -t $(MOUNT_IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f cmd/seaweedfs-mount/Dockerfile.prebuilt \
	  $(MOUNT_ARM64_CONTEXT)

$(RECYCLER_AMD64_TAR): cmd/seaweedfs-consumer-recycler/Dockerfile | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/amd64 \
	  -t $(RECYCLER_IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f cmd/seaweedfs-consumer-recycler/Dockerfile .

$(RECYCLER_ARM64_TAR): cmd/seaweedfs-consumer-recycler/Dockerfile | $(OUTPUT_DIR)
	docker buildx build \
	  --platform linux/arm64 \
	  -t $(RECYCLER_IMAGE_TAG) \
	  --output type=docker,dest=$@ \
	  -f cmd/seaweedfs-consumer-recycler/Dockerfile .

sideload-csi: sideload-csi-amd64 sideload-csi-arm64
sideload-mount: sideload-mount-amd64 sideload-mount-arm64
sideload-recycler: sideload-recycler-amd64 sideload-recycler-arm64
sideload-runtime: sideload-mount sideload-recycler

sideload-csi-amd64: $(DRIVER_AMD64_TAR)
	@for node in $(AMD64_NODES); do \
	  echo ">>> sideloading $(DRIVER_IMAGE_TAG) -> $$node (amd64)"; \
	  $(SCP) $(DRIVER_AMD64_TAR) $$node:/tmp/seaweedfs-csi-driver.tar; \
	  $(SSH) $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-csi-driver.tar && rm /tmp/seaweedfs-csi-driver.tar"; \
	done

sideload-csi-arm64: $(DRIVER_ARM64_TAR)
	@for node in $(ARM64_NODES); do \
	  echo ">>> sideloading $(DRIVER_IMAGE_TAG) -> $$node (arm64)"; \
	  $(SCP) $(DRIVER_ARM64_TAR) $$node:/tmp/seaweedfs-csi-driver.tar; \
	  $(SSH) $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-csi-driver.tar && rm /tmp/seaweedfs-csi-driver.tar"; \
	done

sideload-mount-amd64: $(MOUNT_AMD64_TAR)
	@for node in $(AMD64_NODES); do \
	  echo ">>> sideloading $(MOUNT_IMAGE_TAG) -> $$node (amd64)"; \
	  $(SCP) $(MOUNT_AMD64_TAR) $$node:/tmp/seaweedfs-mount.tar; \
	  $(SSH) $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-mount.tar && rm /tmp/seaweedfs-mount.tar"; \
	done

sideload-mount-arm64: $(MOUNT_ARM64_TAR)
	@for node in $(ARM64_NODES); do \
	  echo ">>> sideloading $(MOUNT_IMAGE_TAG) -> $$node (arm64)"; \
	  $(SCP) $(MOUNT_ARM64_TAR) $$node:/tmp/seaweedfs-mount.tar; \
	  $(SSH) $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-mount.tar && rm /tmp/seaweedfs-mount.tar"; \
	done

sideload-recycler-amd64: $(RECYCLER_AMD64_TAR)
	@for node in $(AMD64_NODES); do \
	  echo ">>> sideloading $(RECYCLER_IMAGE_TAG) -> $$node (amd64)"; \
	  $(SCP) $(RECYCLER_AMD64_TAR) $$node:/tmp/seaweedfs-consumer-recycler.tar; \
	  $(SSH) $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-consumer-recycler.tar && rm /tmp/seaweedfs-consumer-recycler.tar"; \
	done

sideload-recycler-arm64: $(RECYCLER_ARM64_TAR)
	@for node in $(ARM64_NODES); do \
	  echo ">>> sideloading $(RECYCLER_IMAGE_TAG) -> $$node (arm64)"; \
	  $(SCP) $(RECYCLER_ARM64_TAR) $$node:/tmp/seaweedfs-consumer-recycler.tar; \
	  $(SSH) $$node "sudo k3s ctr -n k8s.io images import /tmp/seaweedfs-consumer-recycler.tar && rm /tmp/seaweedfs-consumer-recycler.tar"; \
	done

verify-csi:
	@for node in $(AMD64_NODES) $(ARM64_NODES); do \
	  echo ">>> $$node:"; \
	  $(SSH) $$node "sudo k3s ctr -n k8s.io images ls | grep -F '$(DRIVER_IMAGE_TAG)' || echo '  MISSING'"; \
	done

verify-mount:
	@for node in $(AMD64_NODES) $(ARM64_NODES); do \
	  echo ">>> $$node:"; \
	  $(SSH) $$node "sudo k3s ctr -n k8s.io images ls | grep -F '$(MOUNT_IMAGE_TAG)' || echo '  MISSING'"; \
	done

verify-recycler:
	@for node in $(AMD64_NODES) $(ARM64_NODES); do \
	  echo ">>> $$node:"; \
	  $(SSH) $$node "sudo k3s ctr -n k8s.io images ls | grep -F '$(RECYCLER_IMAGE_TAG)' || echo '  MISSING'"; \
	done

verify-runtime: verify-mount verify-recycler

clean:
	go clean -r -x
	-rm -rf $(OUTPUT_DIR)
