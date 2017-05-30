package main

import (
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"net/http"

	"github.com/davecgh/go-spew/spew"
	"github.com/gorilla/mux"
	dhcp "github.com/krolaw/dhcp4"
)

// Node struct
type Node struct {
	Mac string `json:"MAC"`
	Ip  string `json:"IP"`
}

// Node struct
type Stats struct {
	EthernetName string `json:"Interface"`
	Net          string `json:"Network"`
	Free         int    `json:"Free"`
}

type ApiReq struct {
	Req          string
	NetInterface string
	NetWork      string
	Mac          string
}

type Options struct {
	Option dhcp.OptionCode `json:"option"`
	Value  string          `json:"value"`
}

func handleIP2Mac(res http.ResponseWriter, req *http.Request) {
	vars := mux.Vars(req)

	if index, found := GlobalIpCache.Get(vars["ip"]); found {
		var node = map[string]*Node{
			"result": &Node{Mac: index.(string), Ip: vars["ip"]},
		}

		outgoingJSON, error := json.Marshal(node)

		if error != nil {
			http.Error(res, error.Error(), http.StatusInternalServerError)
			return
		}

		fmt.Fprint(res, string(outgoingJSON))
		return
	}
	http.Error(res, "Not found", http.StatusInternalServerError)
	return
}

func handleMac2Ip(res http.ResponseWriter, req *http.Request) {
	vars := mux.Vars(req)

	if index, found := GlobalMacCache.Get(vars["mac"]); found {
		var node = map[string]*Node{
			"result": &Node{Mac: vars["mac"], Ip: index.(string)},
		}

		outgoingJSON, error := json.Marshal(node)

		if error != nil {
			http.Error(res, error.Error(), http.StatusInternalServerError)
			return
		}

		fmt.Fprint(res, string(outgoingJSON))
		return
	}
	http.Error(res, "Not found", http.StatusInternalServerError)
	return
}

func handleStats(res http.ResponseWriter, req *http.Request) {
	vars := mux.Vars(req)

	if _, ok := ControlIn[vars["int"]]; ok {
		Request := ApiReq{Req: "stats", NetInterface: vars["int"], NetWork: ""}
		ControlIn[vars["int"]] <- Request

		stat := <-ControlOut[vars["int"]]

		outgoingJSON, error := json.Marshal(stat)

		if error != nil {
			http.Error(res, error.Error(), http.StatusInternalServerError)
			return
		}

		fmt.Fprint(res, string(outgoingJSON))
		return
	} else {
		http.Error(res, "Not found", http.StatusInternalServerError)
		return
	}
}

func handleParking(res http.ResponseWriter, req *http.Request) {
	vars := mux.Vars(req)
	InterFaceName, NetWork := InterfaceScopeFromMac(vars["mac"])
	if _, ok := ControlIn[InterFaceName]; ok {
		Request := ApiReq{Req: "parking", NetInterface: InterFaceName, NetWork: NetWork, Mac: vars["mac"]}
		ControlIn[InterFaceName] <- Request
		stat := <-ControlOut[InterFaceName]
		spew.Dump(stat)
	}

	spew.Dump(InterFaceName)
	spew.Dump(NetWork)
}

func handleOverrideOptions(res http.ResponseWriter, req *http.Request) {

	vars := mux.Vars(req)

	var options []Options

	body, err := ioutil.ReadAll(io.LimitReader(req.Body, 1048576))
	if err != nil {
		panic(err)
	}
	if err := req.Body.Close(); err != nil {
		panic(err)
	}
	if err := json.Unmarshal(body, &options); err != nil {
		res.Header().Set("Content-Type", "application/json; charset=UTF-8")
		res.WriteHeader(422) // unprocessable entity
		if err := json.NewEncoder(res).Encode(err); err != nil {
			panic(err)
		}
	}

	var dhcpOptions = make(map[dhcp.OptionCode][]byte)
	for _, option := range options {
		dhcpOptions[option.Option] = []byte(option.Value)
	}

	GlobalOptionMacCache.SetDefault(vars["mac"], dhcpOptions)
	spew.Dump(options)
	spew.Dump(dhcpOptions)
	res.Header().Set("Content-Type", "application/json; charset=UTF-8")
	res.WriteHeader(http.StatusCreated)
	// if err := json.NewEncoder(res).Encode(t); err != nil {
	// 	panic(err)
	// }
}

func handleHelp(res http.ResponseWriter, req *http.Request) {
	fmt.Fprint(res, `Help`)
}
