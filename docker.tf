provider "aws" {
  region     = "us-east-2"
  access_key = "AKIAISD52TBECRVLIVUQ"
  secret_key = "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"
}

variable "zones" {
  description = "Run the EC2 Instances in these Availability Zones"
  type = "list"
  default = ["us-east-2a", "us-east-2b", "us-east-2c"]
}

variable "ranges" {
  description = "The IP ranges to assign to each availability zone"
  type = "list"
  default = ["172.24.0.0/24", "172.24.1.0/24", "172.24.2.0/24"]
}


# Let's create a separate VPC for this infrastructure
resource "aws_vpc" "vpc" {
  cidr_block = "172.24.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "awssd2.webdatalinks.zone"
  }
}

# Add a network gateway
resource "aws_internet_gateway" "default" {
  vpc_id = "${aws_vpc.vpc.id}"
  tags = {
    Name = "awssd2.webdatalinks.zone"
  }
}

# Add 3 subnets, with the IP ranges from above.
resource "aws_subnet" "subnet" {
  count             = 3
  availability_zone = "${element(var.zones, count.index)}"
  vpc_id            = "${aws_vpc.vpc.id}"
  cidr_block        = "${element(var.ranges, count.index)}"
  tags = {
    Name = "${element(var.zones, count.index)}.awssd2.webdatalinks.zone"
  }
}

# Query the routing table ID, which is automatically craeted with the VPC
data "aws_route_table" "main" {
  vpc_id = "${aws_vpc.vpc.id}"
}

# Add a default route to the routing table so the internet is visible
resource "aws_route" "default" {
  route_table_id         = "${data.aws_route_table.main.id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.default.id}"
}

# Associate the created subnets with the routing table
resource "aws_route_table_association" "routing" {
  count          = 3
  subnet_id      = "${element(aws_subnet.subnet.*.id, count.index)}"
  route_table_id = "${data.aws_route_table.main.id}"
}

# Change the default SG configuration to only allow the traffic we want.
resource "aws_default_security_group" "sg" {
  vpc_id      = "${aws_vpc.vpc.id}"

  ingress {
    protocol  = -1
    self      = true
    from_port = 0
    to_port   = 0
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
  tags = {
    Name = "awssd2.webdatalinks.zone"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

# Create the ECS role so the container can connect to the ECS service
resource "aws_iam_role" "iam-role" {
  name = "awssd2-webdatalinks-zone"

  assume_role_policy = "${file("files/ecs-iam-role.json")}"
}

resource "aws_iam_role_policy" "iam-role-policy" {
  name = "awssd2-webdatalinks-zone"
  role = "${aws_iam_role.iam-role.id}"

  policy = "${file("files/ecs-iam-role-policy.json")}"
}

resource "aws_iam_instance_profile" "iam_profile" {
  name  = "awssd2-webdatalinks-zone"
  role = "${aws_iam_role.iam-role.name}"
}

# Launch configurations describe the instance to be launched
resource "aws_launch_configuration" "default" {
  name_prefix                 = "awssd2.webdatalinks.zone-"
  image_id                    = "${data.aws_ami.ubuntu.id}"
  instance_type               = "m4.large"
  user_data                   = <<USERDATA
#!/bin/bash
set -e
useradd -m -s /bin/bash janoszen
mkdir /home/janoszen/.ssh
echo 'ssh-rsa AAAA....' >/home/janoszen/.ssh/authorized_keys
gpasswd -a janoszen sudo
echo 'Defaults  env_reset
Defaults        mail_badpass
Defaults        secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
root    ALL=(ALL:ALL) ALL
%admin ALL=(ALL) NOPASSWD: ALL
%sudo   ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/ecs
echo ECS_CLUSTER=${aws_ecs_cluster.ecs.name} > /etc/ecs/ecs.config
apt-get -q -y update && apt-get -q -y upgrade && apt-get -q -y dist-upgrade
apt-get -q -y install docker.io
mkdir -p /var/log/ecs /etc/ecs /var/lib/ecs/data
sysctl -w net.ipv4.conf.all.route_localnet=1
iptables -t nat -A PREROUTING -p tcp -d 169.254.170.2 --dport 80 -j DNAT --to-destination 127.0.0.1:51679
iptables -t nat -A OUTPUT -d 169.254.170.2 -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 51679
docker run --name ecs-agent \
    --detach=true \
    --restart=on-failure:10 \
    --volume=/var/run/docker.sock:/var/run/docker.sock \
    --volume=/var/log/ecs:/log \
    --volume=/var/lib/ecs/data:/data \
    --net=host \
    --env-file=/etc/ecs/ecs.config \
    --env=ECS_LOGFILE=/log/ecs-agent.log \
    --env=ECS_DATADIR=/data/ \
    --env=ECS_ENABLE_TASK_IAM_ROLE=true \
    --env=ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true \
    amazon/amazon-ecs-agent:latest
userdel -f -r ubuntu
rm -rf /root/.ssh/authorized_keys
USERDATA
  associate_public_ip_address = true
  # Associate the IAM profile tor ECS
  iam_instance_profile = "${aws_iam_instance_profile.iam_profile.name}"
  root_block_device {
    volume_size = "20"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Create the autoscaling group for the host machines
resource "aws_autoscaling_group" "default" {
  availability_zones        = ["${var.zones}"]
  name                      = "awssd2.webdatalinks.zone"
  max_size                  = 3
  min_size                  = 1
  health_check_grace_period = 300
  health_check_type         = "EC2"
  desired_capacity          = 1
  force_delete              = true
  launch_configuration      = "${aws_launch_configuration.default.name}"
  vpc_zone_identifier       = ["${aws_subnet.subnet.*.id}"]
}
#Add the ECS stuff
resource "aws_ecs_cluster" "ecs" {
  name = "awssd2-webdatalinks-zone"
}

resource "aws_ecr_repository" "www" {
  name = "awssd2-webdatalinks-zone"
  provisioner "local-exec" {
    command = "$(aws ecr get-login --region us-east-2) && docker build -t ${aws_ecr_repository.www.name} . && docker tag ${aws_ecr_repository.www.name}:latest ${aws_ecr_repository.www.repository_url}:latest && docker push ${aws_ecr_repository.www.repository_url}:latest"
  }
}

resource "aws_ecs_task_definition" "www" {
  family                = "www"
  container_definitions = <<DEFINITION
[
  {
    "name": "www",
    "image": "${aws_ecr_repository.www.repository_url}",
    "memory": 256,
    "essential": true,
    "portMappings": [
      {
        "hostPort": 80,
        "containerPort": 80,
        "protocol": "tcp"
      }
    ],
    "environment": null,
    "mountPoints": null,
    "volumesFrom": null,
    "hostname": null,
    "user": null,
    "workingDirectory": null,
    "extraHosts": null,
    "logConfiguration": null,
    "ulimits": null,
    "dockerLabels": null
  }
]
DEFINITION
}

# Create load balancer
resource "aws_elb" "elb" {
  name               = "awssd2-webdatalinks-zone"
  security_groups    = ["${aws_default_security_group.sg.id}"]
  subnets            = ["${aws_subnet.subnet.*.id}"]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 30
  }
}

resource "aws_ecs_service" "www" {
  name            = "www"
  cluster         = "${aws_ecs_cluster.ecs.id}"
  task_definition = "${aws_ecs_task_definition.www.arn}"
  iam_role        = "${aws_iam_role.iam-role.arn}"
  depends_on      = ["aws_iam_role_policy.iam-role-policy"]
  desired_count   = 1
  load_balancer {
    elb_name       = "${aws_elb.elb.name}"
    container_name = "www"
    container_port = 80
  }
}

# Route 53
data "aws_route53_zone" "zone" {
  name = "awssd2.webdatalinks.zone."
  private_zone = true
}

resource "aws_route53_record" "www" {
  zone_id = "${data.aws_route53_zone.zone.zone_id}"
  name    = "${data.aws_route53_zone.zone.name}"
  type    = "A"
  alias {
    name                   = "${aws_elb.elb.dns_name}"
    zone_id                = "${aws_elb.elb.zone_id}"
    evaluate_target_health = true
  }
}