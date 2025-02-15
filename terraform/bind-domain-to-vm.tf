# Объявление переменных для пользовательских параметров

variable "folder_id" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "ssh_key_path" {
  type = string
}

# Добавление переменных

locals {
  zone             = "ru-central1-a"
  network_name     = "webserver-network"
  subnet_name      = "webserver-subnet-ru-central1-a"
  sg_name          = "webserver-sg"
  vm_name          = "mywebserver"
  domain_zone_name = "my-domain-zone"
}

# Настройка провайдера

terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.47.0"
    }
  }
}

provider "yandex" {
  zone      = local.zone
  folder_id = var.folder_id
}

# Создание облачной сети

resource "yandex_vpc_network" "webserver-network" {
  name = local.network_name
}

# Создание подсети

resource "yandex_vpc_subnet" "webserver-subnet-b" {
  name           = local.subnet_name
  zone           = local.zone
  network_id     = "${yandex_vpc_network.webserver-network.id}"
  v4_cidr_blocks = ["192.168.1.0/24"]
}

# Создание группы безопасности

resource "yandex_vpc_security_group" "webserver-sg" {
  name        = local.sg_name
  network_id  = "${yandex_vpc_network.webserver-network.id}"
  ingress {
    protocol       = "TCP"
    description    = "http"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  ingress {
    protocol       = "TCP"
    description    = "https"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  ingress {
    protocol       = "TCP"
    description    = "https"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 8080
  }

  ingress {
    protocol       = "TCP"
    description    = "ssh"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }

  egress {
    protocol       = "ANY"
    description    = "any"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}


# Создание образа

resource "yandex_compute_image" "osimage" {
  source_family = "ubuntu-2404-lts-oslogin"
}

# Создание диска

resource "yandex_compute_disk" "boot-disk" {
  name     = "web-server-boot"
  type     = "network-hdd"
  image_id = yandex_compute_image.osimage.id
}

# Создание ВМ

resource "yandex_compute_instance" "mywebserver" {
  name        = local.vm_name
  platform_id = "standard-v2"
  zone        = local.zone

  resources {
    cores  = "2"
    memory = "2"
  }

  boot_disk {
    disk_id = yandex_compute_disk.boot-disk.id
  }

  network_interface {
    subnet_id          = "${yandex_vpc_subnet.webserver-subnet-b.id}"
    nat                = true
    security_group_ids = ["${yandex_vpc_security_group.webserver-sg.id}"]
  }

  metadata = {
    user-data = <<-EOT
    #cloud-config
    users:
      - name: yc-user
        groups: sudo
        shell: /bin/bash
        sudo: 'ALL=(ALL) NOPASSWD:ALL'
        ssh_authorized_keys:
          - ${file("${var.ssh_key_path}")}
    package_update: true
    package_upgrade: true
    packages:
      - nginx
    runcmd:
      - systemctl start nginx
      - systemctl enable nginx
  EOT
    #user-data = "#cloud-config\nusers:\n  - name: yc-user\n    groups: sudo\n    shell: /bin/bash\n    sudo: 'ALL=(ALL) NOPASSWD:ALL'\n    ssh_authorized_keys:\n      - ${file("${var.ssh_key_path}")}"
  }
}

# Создание зоны DNS

resource "yandex_dns_zone" "my-domain-zone" {
  name    = local.domain_zone_name
  zone    = "${var.domain_name}."
  public  = true
}

# Создание ресурсной записи типа А

resource "yandex_dns_recordset" "rsА1" {
  zone_id = yandex_dns_zone.my-domain-zone.id
  name    = "${yandex_dns_zone.my-domain-zone.zone}"
  type    = "A"
  ttl     = 600
  data    = ["${yandex_compute_instance.mywebserver.network_interface.0.nat_ip_address}"]
}


# Coздание целевой группы

resource "yandex_lb_target_group" "docker-test-stand" {
  name      = "docker-test-stand"
  target {
    subnet_id = yandex_vpc_subnet.webserver-subnet-b.id
    address   = yandex_compute_instance.mywebserver.network_interface.0.ip_address
  }
}

# Coздание балансировщик нагрузки

resource "yandex_lb_network_load_balancer" "docker-test-stand" {
  name = "docker-test-stand"
  deletion_protection = false

  listener {
    name = "listener-http"
    protocol = "tcp"
    port = 80
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.docker-test-stand.id

    healthcheck {
      name = "http-healthcheck"
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}

output "external_ip" {
  value = yandex_compute_instance.mywebserver.network_interface[0].nat_ip_address
  description = "External IP address of the VM"
}