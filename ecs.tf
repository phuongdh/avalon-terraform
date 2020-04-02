## EC2

### Compute

resource "aws_autoscaling_group" "app" {
  name                 = "tf-test-asg"
  vpc_zone_identifier  = module.vpc.public_subnets
  min_size             = var.autoscale_min
  max_size             = var.autoscale_max
  desired_capacity     = var.autoscale_desired
  launch_configuration = aws_launch_configuration.app.name
}

# resource "aws_ecs_capacity_provider" "test" {
#   name = "test"

#   auto_scaling_group_provider {
#     auto_scaling_group_arn         = aws_autoscaling_group.app.arn
#     managed_termination_protection = "ENABLED"

#     managed_scaling {
#       maximum_scaling_step_size = 1000
#       minimum_scaling_step_size = 1
#       status                    = "ENABLED"
#       target_capacity           = 10
#     }
#   }
# }

data "template_file" "cloud_config" {
  template = file("${path.module}/scripts/cloud_config.yml")

  vars = {
    aws_region         = var.aws_region
    ecs_cluster_name   = aws_ecs_cluster.main.name
    ecs_log_level      = "info"
    ecs_agent_version  = "latest"
    ecs_log_group_name = aws_cloudwatch_log_group.ecs.name
  }
}

data "aws_ami" "stable_coreos" {
  most_recent = true

  filter {
    name   = "description"
    values = ["CoreOS Container Linux stable *"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["595879546273"] # CoreOS
}

resource "aws_launch_configuration" "app" {
  security_groups = [
    "${aws_security_group.instance_sg.id}",
  ]

  key_name                    = var.ec2_keyname
  image_id                    = data.aws_ami.stable_coreos.id
  instance_type               = var.ecs_instance_type
  iam_instance_profile        = aws_iam_instance_profile.app.name
  user_data                   = data.template_file.cloud_config.rendered
  associate_public_ip_address = true

  lifecycle {
    create_before_destroy = true
  }
}

# ### Security

# resource "aws_security_group" "lb_sg" {
#   description = "controls access to the application ELB"

#   vpc_id = "${aws_vpc.main.id}"
#   name   = "tf-ecs-lbsg"

#   ingress {
#     protocol    = "tcp"
#     from_port   = 80
#     to_port     = 80
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   egress {
#     from_port = 0
#     to_port   = 0
#     protocol  = "-1"

#     cidr_blocks = [
#       "0.0.0.0/0",
#     ]
#   }
# }

resource "aws_security_group" "instance_sg" {
  description = "controls direct access to application instances"
  vpc_id      = module.vpc.vpc_id
  name        = "${local.namespace}-ecs-instsg"

  ingress {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22

    cidr_blocks = [var.vpc_cidr_block]
  }

  ingress {
    protocol  = "tcp"
    from_port = 32768
    to_port   = 61000

    security_groups = [aws_security_group.alb.id,]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

## ECS

resource "aws_ecs_cluster" "main" {
  name = "${local.namespace}-cluster"
}

# Don't group unrelated containers into 1 task definition 
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/application_architecture.html
data "template_file" "task_definition" {
  template = file("${path.module}/scripts/task_definition.json")
  
  vars = {
    image_url        = "ghost:latest"
    container_name   = "ghost"
    log_group_region = var.aws_region
    log_group_name   = aws_cloudwatch_log_group.app.name
  }
}

resource "aws_ecs_task_definition" "ghost" {
  family                = "tf_example_ghost_td"
  container_definitions = data.template_file.task_definition.rendered
}

resource "aws_ecs_service" "test" {
  name            = "tf-example-ecs-ghost"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.ghost.arn
  desired_count   = 1
  iam_role        = aws_iam_role.ecs_service.name

  load_balancer {
    target_group_arn = aws_alb_target_group.test.id
    container_name   = "ghost"
    container_port   = "2368"
  }

  depends_on = [
    aws_iam_role_policy.ecs_service,
    aws_alb_listener.front_end,
  ]
}

## IAM

resource "aws_iam_role" "ecs_service" {
  name = "${local.namespace}-ecs-role"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "ecs_service" {
  name = "${local.namespace}-ecs-policy"
  role = aws_iam_role.ecs_service.name

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:Describe*",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:RegisterTargets"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.namespace}-ecs-instance-profile"
  role = aws_iam_role.app_instance.name
}

resource "aws_iam_role" "app_instance" {
  name = "${local.namespace}-ecs-instance-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

data "template_file" "instance_profile" {
  template = file("${path.module}/scripts/instance_profile_policy.json")

  vars = {
    app_log_group_arn = aws_cloudwatch_log_group.app.arn
    ecs_log_group_arn = aws_cloudwatch_log_group.ecs.arn
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${local.namespace}-ecs-instance-policy"
  role   = aws_iam_role.app_instance.name
  policy = data.template_file.instance_profile.rendered
}

## ALB

resource "aws_alb_target_group" "test" {
  name     = "tf-example-ecs-ghost"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
}

resource "aws_alb_listener" "front_end" {
  load_balancer_arn = aws_alb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.test.id
    type             = "forward"
  }
}
