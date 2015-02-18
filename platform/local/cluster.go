// Copyright 2015 CoreOS, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package local

import (
	"fmt"

	"github.com/coreos/mantle/Godeps/_workspace/src/github.com/vishvananda/netlink"
	"github.com/coreos/mantle/Godeps/_workspace/src/github.com/vishvananda/netns"
	"github.com/coreos/mantle/network"
	"github.com/coreos/mantle/util"
)

type LocalCluster struct {
	SSHAgent   *network.SSHAgent
	Dnsmasq    *Dnsmasq
	SimpleEtcd *SimpleEtcd
	nshandle   netns.NsHandle
}

func NewLocalCluster() (*LocalCluster, error) {
	lc := &LocalCluster{}

	var err error
	lc.nshandle, err = NsCreate()
	if err != nil {
		return nil, err
	}

	dialer := NewNsDialer(lc.nshandle)
	lc.SSHAgent, err = network.NewSSHAgent(dialer)
	if err != nil {
		lc.nshandle.Close()
		return nil, err
	}

	// dnsmasq and etcd much be lunched in the new namespace
	nsExit, err := NsEnter(lc.nshandle)
	if err != nil {
		return nil, err
	}
	defer nsExit()

	lc.Dnsmasq, err = NewDnsmasq()
	if err != nil {
		lc.nshandle.Close()
		return nil, err
	}

	lc.SimpleEtcd, err = NewSimpleEtcd()
	if err != nil {
		lc.Dnsmasq.Destroy()
		lc.nshandle.Close()
		return nil, err
	}

	return lc, nil
}

func (lc *LocalCluster) NewCommand(name string, arg ...string) util.Cmd {
	cmd := NewNsCommand(lc.nshandle, name, arg...)
	sshEnv := fmt.Sprintf("SSH_AUTH_SOCK=%s", lc.SSHAgent.Socket)
	cmd.Env = append(cmd.Env, sshEnv)
	return cmd
}

func (lc *LocalCluster) EtcdEndpoint() string {
	// hackydoo
	bridge := "br0"
	for _, seg := range lc.Dnsmasq.Segments {
		if bridge == seg.BridgeName {
			return fmt.Sprintf("http://%s:%d", seg.BridgeIf.DHCPv4[0].IP, lc.SimpleEtcd.Port)
		}
	}
	panic("Not a valid bridge!")
}

func (lc *LocalCluster) NewTap(bridge string) (*TunTap, error) {
	nsExit, err := NsEnter(lc.nshandle)
	if err != nil {
		return nil, err
	}
	defer nsExit()

	tap, err := AddLinkTap("")
	if err != nil {
		return nil, fmt.Errorf("tap failed: %v", err)
	}

	err = netlink.LinkSetUp(tap)
	if err != nil {
		return nil, fmt.Errorf("tap up failed: %v", err)
	}

	br, err := netlink.LinkByName(bridge)
	if err != nil {
		return nil, fmt.Errorf("bridge failed: %v", err)
	}

	err = netlink.LinkSetMaster(tap, br.(*netlink.Bridge))
	if err != nil {
		return nil, fmt.Errorf("set master failed: %v", err)
	}

	return tap, nil
}

func (lc *LocalCluster) Destroy() error {
	var err error
	firstErr := func(e error) {
		if e != nil && err == nil {
			err = e
		}
	}

	firstErr(lc.SimpleEtcd.Destroy())
	firstErr(lc.Dnsmasq.Destroy())
	firstErr(lc.SSHAgent.Close())
	firstErr(lc.nshandle.Close())
	return err
}
