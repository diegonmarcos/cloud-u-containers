{
	admin off
	persist_config off
	auto_https off
}

# gitea-gate — the only door to gitea's HTTP (gitea listens on a unix socket
# no other container mounts). Gitea honours @USER_HEADER@ from ANY peer, so
# the header — and X-Real-IP, which gitea prefers over X-Forwarded-For — only
# survives from the measured edge address(es), for the vhost the edge
# authenticates. The hub's .app catalog routes reach us from the same address
# with Host gitea.app, so the Host half is not decoration.
:@PORT@ {
	@not_edge {
		not {
			remote_ip @TRUSTED@
			host @HOST@
		}
	}
	request_header @not_edge -@USER_HEADER@
	request_header @not_edge -X-Real-IP
	reverse_proxy unix/@SOCKET@ {
		flush_interval -1
	}
}
