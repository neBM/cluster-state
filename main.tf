terraform {
  backend "pg" {}
}

module "dummy" {
  source = "./modules/dummy"
}

module "media-centre" {
  source = "./modules/media-centre"
}

module "coder" {
  source = "./modules/coder"
}

module "uptime" {
  source = "./modules/uptime"
}
