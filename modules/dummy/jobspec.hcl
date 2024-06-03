job "hello-world" {
  datacenters = ["*"]
  meta {
    foo = "bar"
  }
  group "servers" {
    count = 1
    network {
      port "www" {
        to = 8001
      }
    }
    service {
      provider = "nomad"
      port     = "www"
    }
    task "web" {
      driver = "docker"
      config {
        image   = "busybox:1"
        command = "httpd"
        args = ["-v", "-f", "-p", "${NOMAD_PORT_www}", "-h", "/local"]
        ports = ["www"]
      }
      template {
        data        = <<-EOF
                      <h1>Hello, Nomad!</h1>
                      <ul>
                        <li>Task: {{env "NOMAD_TASK_NAME"}}</li>
                        <li>Group: {{env "NOMAD_GROUP_NAME"}}</li>
                        <li>Job: {{env "NOMAD_JOB_NAME"}}</li>
                        <li>Metadata value for foo: {{env "NOMAD_META_foo"}}</li>
                        <li>Currently running on port: {{env "NOMAD_PORT_www"}}</li>
                      </ul>
                      EOF
        destination = "local/index.html"
      }
      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}