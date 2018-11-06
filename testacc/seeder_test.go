package kubic_init_acctest_test

import (
	"fmt"
	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"golang.org/x/crypto/ssh"
	"testing"
)

func TestCart(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Kubic-Init Suite")
}

var _ = Describe("Kubic-seeder", func() {
	Describe("Run basic test", func() {
		Context("With more than 300 pages", func() {
			It("should be a novel", func() {
				Expect("NOVEL").To(Equal("NOVEL"))
			})
		})

		Context("Run something via ssh", func() {
			It("Run on localhost ssh cmd", func() {
				// create connection
				host := "localhost:22"
				client, session, err := connectToHost("root", host)
				if err != nil {
					panic(err)
				}
				// run something
				cmd := "whoami"
				out, err := session.CombinedOutput(cmd)
				if err != nil {
					panic(err)
				}
				fmt.Println(string(out))
				client.Close()

				Expect("root").To(Equal(out))
			})
		})
	})
})

func connectToHost(user, host string) (*ssh.Client, *ssh.Session, error) {
	sshConfig := &ssh.ClientConfig{
		User: user,
		Auth: []ssh.AuthMethod{ssh.Password("linux")},
	}
	sshConfig.HostKeyCallback = ssh.InsecureIgnoreHostKey()

	client, err := ssh.Dial("tcp", host, sshConfig)
	if err != nil {
		return nil, nil, err
	}

	session, err := client.NewSession()
	if err != nil {
		client.Close()
		return nil, nil, err
	}

	return client, session, nil
}
