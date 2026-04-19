REGISTRY ?= registry.brmartin.co.uk/ben/cluster-state
IMAGE     := $(REGISTRY)/rpi5-dra-driver
COMMIT    := $(shell git rev-parse --short HEAD)
VERSION   ?= dev
OUTPUT    := _output/rpi5-dra-driver

.PHONY: build container push clean deps

deps:
	go mod tidy

build: $(OUTPUT)

$(OUTPUT):
	mkdir -p _output
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-s -w' -o $(OUTPUT) ./cmd/rpi5-dra-driver

container: build
	docker build -t $(IMAGE):$(VERSION) -t $(IMAGE):$(COMMIT) .

push: container
	docker push $(IMAGE):$(VERSION)
	docker push $(IMAGE):$(COMMIT)

clean:
	rm -rf _output
