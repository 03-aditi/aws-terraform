provider "aws" {
   region = "ap-south-1"
   profile = "aditi"
}





/*   create key   */



resource "tls_private_key" "key_pvt" {
  algorithm   = "RSA"
}







/*   save key on local system   */



resource "local_file" "keyfile" {
  depends_on = [ tls_private_key.key_pvt, ]
  content = tls_private_key.key_pvt.private_key_pem
  filename = "key.pem"
}







/*   sending public key to aws   */



resource "aws_key_pair" "key_pub" {
  depends_on = [ local_file.keyfile, ]
  key_name   = "task-key"
  public_key = tls_private_key.key_pvt.public_key_openssh
}





/*   create security group to allow 80, 22, 443 port traffic for ec2 instance */




resource "aws_security_group" "sg1" {
  depends_on = [ aws_key_pair.key_pub, ]
  name        = "web_sg"
  description = "Allow 80 and 22 port"
  vpc_id      = "vpc-0214086a"

  ingress {
    description = "80 http"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "22 ssh"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description = "443 https"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sec_gp"
  }
}







/*    create ec2 instance with webserver  */





resource "aws_instance" "web" {
      depends_on = [ aws_security_group.sg1 ]
      ami = "ami-0447a12f28fddb066"
      instance_type = "t2.micro"
      key_name = "task-key"
      security_groups = [ "web_sg" ]
      tags = {
        Name = "os1"
      }

     connection {
       type     = "ssh"
       user     = "ec2-user"
       private_key = tls_private_key.key_pvt.private_key_pem
       host     = aws_instance.web.public_ip
  }

     provisioner "remote-exec" {
         inline = [
                 "sudo yum install httpd php git -y",
                 "sudo systemctl restart httpd",
                 "sudo systemctl enable httpd"  ]
  }
}







/*   create ebs volume to store webserver data permanently  */




resource "aws_ebs_volume" "ebs_web" {
  depends_on = [ aws_instance.web, ]
  availability_zone = aws_instance.web.availability_zone
  size              = 1

  tags = {
    Name = "ebs1"
  }
} 







/*    attach the created ebs volume to webserver ec2 instance and mount the disk to var/www/html folder   */




resource "aws_volume_attachment" "ebs_att" {
  depends_on = [ aws_ebs_volume.ebs_web, ]
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ebs_web.id
  instance_id = aws_instance.web.id
  force_detach = true

   connection {
       type     = "ssh"
       user     = "ec2-user"
       private_key = tls_private_key.key_pvt.private_key_pem
       host     = aws_instance.web.public_ip
  }
  
   provisioner "remote-exec" {
         inline = [
                 "sudo mkfs.ext4 /dev/xvdh",
                 "sudo mount /dev/xvdh /var/www/html/",
                 "sudo rm -rf /var/www/html/*",
                 "sudo git clone https://github.com/aditi-ag03/devops1.git /var/www/html/"  ]
  }
  
}



/*   create s3 bucket to store the img   */



resource "aws_s3_bucket" "s3bucket" {
  depends_on = [ aws_volume_attachment.ebs_att ]
  bucket = "web-bkt"
  acl    = "public-read"

  tags = {
    Name        = "web_bucket"
  }
}





/*       create local variable for s3 bucket origin id    */


locals {
  depends_on = [ aws_s3_bucket.s3bucket ]
  s3_origin_id = "myS3Origin"
}




/*    upload the image object in s3 bucket    */



resource "aws_s3_bucket_object" "object" {
  depends_on = [ aws_s3_bucket.s3bucket ] 
  bucket = "web-bkt"
  key    = "cat.jpg"
  source = "G:/mlops-ws/Deep Learning/CNN/dogs-cats-images/prediction/cat2.jpg"
  etag = filemd5("G:/mlops-ws/Deep Learning/CNN/dogs-cats-images/prediction/cat2.jpg")
  acl = "public-read"
}



/*     create cloudfront distrubution and add s3 object with it   */


resource "aws_cloudfront_distribution" "cf" {
  depends_on = [ aws_s3_bucket_object.object ]
  origin {
    domain_name = aws_s3_bucket.s3bucket.bucket_regional_domain_name
    origin_id   = local.s3_origin_id
  }

  enabled             = true
  is_ipv6_enabled     = true


  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 120
    max_ttl                = 86400
  }


  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }


  viewer_certificate {
    cloudfront_default_certificate = true
  }
}





/*        providing cloudfront url to the web page hosted on instance    */


resource "null_resource" "null_web" {
     depends_on = [ aws_cloudfront_distribution.cf ]
     connection {
       type     = "ssh"
       user     = "ec2-user"
       private_key = tls_private_key.key_pvt.private_key_pem
       host     = aws_instance.web.public_ip
  }
       provisioner "remote-exec" {
         inline = [
                 "sudo sed -i 's@URL@https://${aws_cloudfront_distribution.cf.domain_name}/${aws_s3_bucket_object.object.key}@g' /var/www/html/index.php",
                  ]        
               }
}




/*        displaying the public ip of instance    */



output "pub_ip" {
    depends_on = [ null_resource.null_web ]
    value = aws_instance.web.public_ip
}


