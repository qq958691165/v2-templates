terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.4.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.11"
    }
  }
}

variable "disk_size" {
  description = "Disk size (__ GB)"
  default     = 10
}

variable "cpu" {
  description = "CPU (__ cores)"
  default     = 4
  validation {
    condition = contains([
      "4",
      "6",
      "8"
    ], var.cpu)
    error_message = "Invalid cpu!"   
}
}

variable "memory" {
  description = "Memory (__ GB)"
  default     = 4
  validation {
    condition = contains([
      "4",
      "6",
      "8",
      "10"
    ], var.memory)
    error_message = "Invalid memory!"  
}
}

variable "dotfiles_uri" {
  description = <<-EOF
  Dotfiles repo URI (optional)

  see https://dotfiles.github.io
  EOF
  default = ""
}

variable "image" {
  description = <<-EOF
  Container images from coder-com

  EOF
  default = "codercom/enterprise-java:ubuntu"
  validation {
    condition = contains([
      "codercom/enterprise-java:ubuntu"
    ], var.image)
    error_message = "Invalid image!"   
}  
}

variable "extension" {
  description = "VS Code extension"
  default     = "redhat.java"
  validation {
    condition = contains([
      "redhat.java"
    ], var.extension)
    error_message = "Invalid VS Code extension!"  
}
}

variable "repo" {
  description = <<-EOF
  Code repository to clone with SSH
  e.g., mark-theshark/java_helloworld.git
  EOF
  default = ""
}

variable "folder_path" {
  description = <<-EOF
 Folder to add to VS Code (optional)
e.g.,
/home/coder (default)
  EOF
  default = "/home/coder"
}

variable "code-server" {
  description = "code-server release"
  default     = "4.5.0"
  validation {
    condition = contains([
      "4.5.0",
      "4.4.0",
      "4.3.0",
      "4.2.0"
    ], var.code-server)
    error_message = "Invalid code-server!"   
}
}

variable "jetbrains-ide" {
  description = "JetBrains IntelliJ IDE (oldest are Projector-tested by JetBrains s.r.o., Na Hrebenech II 1718/10, Prague, 14000, Czech Republic)"
  default     = "IntelliJ IDEA Community Edition 2022.1.3"
  validation {
    condition = contains([
      "IntelliJ IDEA Community Edition 2022.1.3",
      "IntelliJ IDEA Community Edition 2021.3",
      "IntelliJ IDEA Ultimate 2022.1.3",
      "IntelliJ IDEA Ultimate 2021.3"
    ], var.jetbrains-ide)
    error_message = "Invalid JetBrains IDE!"   
}
}



variable "use_kubeconfig" {
  type        = bool
  sensitive   = true
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
}

variable "workspaces_namespace" {
  type        = string
  sensitive   = true
  description = "The namespace to create workspaces in (must exist prior to creating workspaces)"
  default     = "oss"
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}

resource "coder_agent" "coder" {
  os   = "linux"
  arch = "amd64"
  dir = "/home/coder"
  startup_script = <<EOT
#!/bin/bash

# use coder CLI to clone and install dotfiles

coder dotfiles -y ${var.dotfiles_uri} 2>&1 > ~/dotfiles.log

# install projector into /home/coder

PROJECTOR_BINARY=/home/coder/.local/bin/projector

if [ -f $PROJECTOR_BINARY ]; then
    echo 'projector has already been installed - check for update'
    /home/coder/.local/bin/projector self-update | tee projector.log
else
    echo 'installing projector'
    pip3 install projector-installer --user | tee -a projector.log
fi

echo 'access projector license terms'
/home/coder/.local/bin/projector --accept-license | tee -a projector.log

PROJECTOR_CONFIG_PATH=/home/coder/.projector/configs/intellij

if [ -d "$PROJECTOR_CONFIG_PATH" ]; then
    echo 'projector has already been configured and the JetBrains IDE downloaded - skip step' | tee -a projector.log
else
    echo 'autoinstalling IDE and creating projector config folder'
    /home/coder/.local/bin/projector ide autoinstall --config-name "intellij" --ide-name "${var.jetbrains-ide}" --hostname=localhost --port 8997 --use-separate-config --password coder | tee -a projector.log

    # delete the configuration's run.sh input parameters that check password tokens since tokens do not work with coder_app yet passed in the querystring

    grep -iv "HANDSHAKE_TOKEN" $PROJECTOR_CONFIG_PATH/run.sh > temp && mv temp $PROJECTOR_CONFIG_PATH/run.sh | tee -a projector.log
    chmod +x $PROJECTOR_CONFIG_PATH/run.sh | tee -a projector.log

    echo "creation of intellij configuration complete" | tee -a projector.log
    
fi

# start JetBrains projector-based IDE
/home/coder/.local/bin/projector run intellij &

# install and start code-server
curl -fsSL https://code-server.dev/install.sh | sh  | tee code-server-install.log
code-server --auth none --port 13337 | tee code-server-install.log &

# clone repo
ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts
git clone --progress git@github.com:${var.repo} 2>&1 | tee repo-clone.log

# install VS Code extensions into code-server
SERVICE_URL=https://open-vsx.org/vscode/gallery ITEM_URL=https://open-vsx.org/vscode/item code-server --install-extension ${var.extension} | tee vs-code-extension.log

EOT
}

# code-server
resource "coder_app" "code-server" {
  agent_id      = coder_agent.coder.id
  name          = "code-server"
  icon          = "https://cdn.icon-icons.com/icons2/2107/PNG/512/file_type_vscode_icon_130084.png"
  url           = "http://localhost:13337?folder=${var.folder_path}"
  relative_path = true  
}

resource "coder_app" "intellij" {
  agent_id      = coder_agent.coder.id
  name          = "${var.jetbrains-ide}"
  icon          = "https://upload.wikimedia.org/wikipedia/commons/9/9c/IntelliJ_IDEA_Icon.svg"
  url           = "http://localhost:8997/"
  relative_path = true
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home-directory
  ]    
  metadata {
    name = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    namespace = "oss"
  }
  spec {
    security_context {
      run_as_user = "1000"
      fs_group    = "1000"
    }     
    container {
      name    = "clion"
      image   = "docker.io/marktmilligan/clion-rust:latest"
      command = ["sh", "-c", coder_agent.coder.init_script]
      security_context {
        run_as_user = "1000"
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.coder.token
      }
      resources {
        requests = {
          cpu    = "500m"
          memory = "3500Mi"
        }        
        limits = {
          cpu    = "${var.cpu}"
          memory = "${var.memory}G"
        }
      }        
      volume_mount {
        mount_path = "/home/coder"
        name       = "home-directory"
      }      
    }
    volume {
      name = "home-directory"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home-directory.metadata.0.name
      }
    }          
  }
}

resource "kubernetes_persistent_volume_claim" "home-directory" {
  metadata {
    name      = "home-coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}"
    namespace = var.workspaces_namespace
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${var.disk_size}Gi"
      }
    }
  }
}
