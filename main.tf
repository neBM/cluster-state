terraform {
  required_version = ">= 1.2.0, < 2.0.0"
  backend "pg" {}
}

module "dummy" {
  source = "./modules/dummy"
}

module "media-centre" {
  source = "./modules/media-centre"
}

module "plextraktsync" {
  source = "./modules/plextraktsync"
}

module "matrix" {
  source = "./modules/matrix"
}

module "elk" {
  source = "./modules/elk"
}

module "renovate" {
  source = "./modules/renovate"
}

module "plugin-csi" {
  source = "./modules/plugin-csi"
}

module "forgejo" {
  source = "./modules/forgejo"
}

module "keycloak" {
  source = "./modules/keycloak"
}

module "ollama" {
  source = "./modules/ollama"
}

module "jayne-martin-counselling" {
  source = "./modules/jayne-martin-counselling"
}

module "monica" {
  source = "./modules/monica"
}

module "n8n" {
  source = "./modules/n8n"
}
