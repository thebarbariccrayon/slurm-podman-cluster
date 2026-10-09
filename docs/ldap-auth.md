# LDAP Users and Login

Cluster users come from an LDAP directory. By default that is the `ldap` service in this stack, an OpenLDAP server seeded with a local admin account and demo users. Everything that needs to know about users reads the same directory:

- **Slurm nodes** (controller, compute nodes, login node, `slurmrestd`) resolve users and groups through `nslcd`, so an LDAP user has the same UID, GID and groups everywhere and can run jobs.
- **The login node** accepts SSH password logins for LDAP users, checked against the directory.
- **Slurm accounting:** the one-shot `directory-sync` service turns LDAP groups into Slurm accounts and creates home directories.
- **The Slurm-web dashboard** requires an LDAP login. There is no anonymous access.

The local `hpcuser` account (UID 2000) still exists on every node for SSH key logins. It is not in LDAP, so it cannot sign in to the dashboard.

## Demo Directory

| User    | Password | Groups                 | Slurm account(s)                 | Dashboard role | Slurm admin |
|---------|----------|------------------------|----------------------------------|----------------|-------------|
| `admin` | `admin`  | `admins`               | `root`                           | `admin`        | yes         |
| `alice` | `demo`   | `physics`              | `physics`                        | `user`         | no          |
| `bob`   | `demo`   | `physics`              | `physics`                        | `user`         | no          |
| `carol` | `demo`   | `biology`              | `biology`                        | `user`         | no          |
| `dave`  | `demo`   | `biology`, `chemistry` | `biology` (default), `chemistry` | `user`         | no          |
| `erin`  | `demo`   | `chemistry`            | `chemistry`                      | `user`         | no          |

- **Passwords:** set them before the first start with `DEMO_ADMIN_PASSWORD` and `DEMO_USER_PASSWORD` in `.env`. The directory manager (`cn=manager,dc=cluster,dc=local`) uses `LDAP_ROOT_PASSWORD`, default `ldaproot`.
- **Seeding only happens once.** The directory is seeded when its volume is empty, so later password changes need `make clean` (which deletes all volumes) or `ldappasswd`.
- **IDs:** users have UIDs 3000–3005. The groups are `posixGroup` entries: `admins` (3000), `physics` (4001), `biology` (4002) and `chemistry` (4003). Each user's primary group is their research group.
- **Homes** are `/shared/home/<user>`, on the volume shared by all nodes.

The directory is published on `127.0.0.1:3389` for tools on the Mac:

    ldapsearch -x -H ldap://localhost:3389 -b dc=cluster,dc=local '(objectClass=posixAccount)' uid cn

## Demo Walkthrough

Sign in to the login node as a demo user and submit jobs. Jobs run as that user on the compute nodes and are charged to their default account:

    ssh -p 2222 alice@localhost            # password: demo
    sbatch -J alice-demo --wrap "sleep 300"
    squeue -o "%i %u %a %j %T"

Or submit as any user from the controller without a password:

    podman exec slurm-controller su - carol -c 'sbatch -J carol-demo --wrap "sleep 300"'
    podman exec slurm-controller su - dave -c 'sbatch -A chemistry -J dave-chem --wrap "sleep 300"'

Then sign in to <http://localhost:5011>:

- As `alice`, the job list shows only alice's jobs.
- As `admin`, every user's jobs are visible.

`admin` is also a Slurm administrator, so `ssh -p 2222 admin@localhost` can run `scancel` and `scontrol` on anyone's jobs. Accounting is not enforced (`AccountingStorageEnforce` is unset), so accounts label jobs and set defaults but do not block submissions.

## Adding Users

Add entries with the directory manager, then run `make sync-users` to create the home directory and Slurm association. This example adds `frank` to `physics`:

    podman exec -i ldap ldapadd -x -H ldap://localhost -D cn=manager,dc=cluster,dc=local -w ldaproot <<EOF
    dn: uid=frank,ou=people,dc=cluster,dc=local
    objectClass: inetOrgPerson
    objectClass: posixAccount
    uid: frank
    cn: Frank Physicist
    sn: Physicist
    uidNumber: 3006
    gidNumber: 4001
    homeDirectory: /shared/home/frank
    loginShell: /bin/bash
    userPassword: $(podman exec ldap slappasswd -s frankpw)

    dn: cn=physics,ou=groups,dc=cluster,dc=local
    changetype: modify
    add: memberUid
    memberUid: frank
    EOF
    make sync-users

The new user resolves on every node immediately. `nslcd` does not cache, so no restart is needed. `make sync-users` is safe to rerun:

- It creates missing homes under `/shared/home`.
- For every group in `SLURM_ACCOUNT_GROUPS` (default `physics biology chemistry`), it adds the account and its members to Slurm.
- It makes members of `SLURMWEB_ADMIN_GROUP` (default `admins`) Slurm administrators.
- It never deletes anything. To remove a user, delete them from LDAP and run `sacctmgr delete user <name>`.

A user whose home is missing gets one created at their first SSH login (`pam_mkhomedir`).

## Dashboard Roles

The gateway checks the username and password against the directory, collects the user's groups and issues a signed token. The agent maps groups to roles (`slurm_web_policy` in `docker-compose.yml`):

| Role    | Who                               | Jobs                             | Other actions                                                                              |
|---------|-----------------------------------|----------------------------------|--------------------------------------------------------------------------------------------|
| `user`  | every authenticated user          | only their own, current and past | dashboard stats, nodes, partitions, QOS, accounts, associations, reservations, cache stats |
| `admin` | members of `SLURMWEB_ADMIN_GROUP` | every user's, current and past   | additionally the jobs chart on the dashboard and `cache-reset`                             |

The agent enforces the job restriction on the server, not just in the UI. Job lists, the jobs running on a node, a single job's details and job history are all filtered: a job is the user's own when its Slurm owner matches the LDAP login name (ignoring case). Someone else's job ID returns "not found". This relies on `slurmrestd` resolving job owners' names, which is why it runs `nslcd` too. The dashboard's job counts are cluster-wide totals and show no job details. The jobs-over-time chart needs full job access, so it is hidden for the `user` role.

There is no anonymous access. The gateway rejects anonymous sessions (HTTP 401 on `/api/anonymous`), and the policy has no `anonymous` role, so even a token without a login would get no permissions.

## Using a Site Directory

To use an existing directory instead of the demo one, copy the example and fill in its details. Compose reads `.env` automatically, and it is gitignored:

    cp .env.example .env
    $EDITOR .env
    make up

The Slurm nodes (`nslcd`) and the gateway both use `LDAP_URI`, the two bases, the bind DN and password, and `LDAP_STARTTLS`. The remaining variables only affect the gateway. The demo `ldap` service keeps running but is no longer used.

| Variable                       | Purpose                                                                   | Default                         |
|--------------------------------|---------------------------------------------------------------------------|---------------------------------|
| `LDAP_URI`                     | `ldap://host`, `ldaps://host` or `ldap://host:port`                       | `ldap://ldap`                   |
| `LDAP_USER_BASE`               | Subtree containing user entries                                           | `ou=people,dc=cluster,dc=local` |
| `LDAP_GROUP_BASE`              | Subtree containing group entries                                          | `ou=groups,dc=cluster,dc=local` |
| `LDAP_BIND_DN`                 | Service account for searches; unset for anonymous search                  | unset                           |
| `LDAP_BIND_PASSWORD`           | Password for `LDAP_BIND_DN`                                               | unset                           |
| `LDAP_STARTTLS`                | `yes` to upgrade an `ldap://` connection with StartTLS                    | `no`                            |
| `SLURM_ACCOUNT_GROUPS`         | LDAP groups that `directory-sync` mirrors into Slurm accounts             | `physics biology chemistry`     |
| `SLURMWEB_ADMIN_GROUP`         | Group whose members get the dashboard `admin` role and Slurm AdminLevel   | `admins`                        |
| `LDAP_RESTRICTED_GROUPS`       | Only members of this group may sign in to the dashboard                   | unset (all users)               |
| `LDAP_CACERT_PEM`              | PEM text of the CA that signed the server certificate (gateway only)      | unset (system CAs)              |
| `LDAP_USER_CLASS`              | Object class of user entries                                              | `posixAccount`                  |
| `LDAP_USER_NAME_ATTRIBUTE`     | Attribute holding the login name                                          | `uid`                           |
| `LDAP_USER_FULLNAME_ATTRIBUTE` | Attribute holding the display name                                        | `cn`                            |
| `LDAP_GROUP_OBJECT_CLASSES`    | Object class of group entries                                             | `posixGroup` and `groupOfNames` |
| `LDAP_GROUP_NAME_ATTRIBUTE`    | Attribute holding the group name                                          | `cn`                            |
| `LDAP_LOOKUP_AS_USER`          | `yes` to read groups as the signed-in user instead of the service account | upstream default                |

**Requirements for the Slurm side:**

- Users need `posixAccount` attributes: `uidNumber`, `gidNumber` and `homeDirectory`. Homes should be under `/shared/home` if `directory-sync` is to create them.
- LDAP login names must match the names jobs run under, because the dashboard's own-jobs filter compares the two.
- `nslcd` uses the system CA bundle. A server certificate from an internal CA is accepted by the gateway (`LDAP_CACERT_PEM`) but not yet by the nodes.

**Single values only:** `LDAP_RESTRICTED_GROUPS` and `LDAP_GROUP_OBJECT_CLASSES` are lists in Slurm-web, but each variable holds a single value. To allow several groups, edit the `restricted_groups` line under `slurm_web_gateway` in `docker-compose.yml` and put one group per indented line:

    restricted_groups=
      hpc-users
      hpc-staff

**Applying changes:** settings are rendered when containers are created. After changing `.env`, recreate the affected services:

    make up
    podman compose up -d --force-recreate slurm-web-agent slurm-web-gateway

### Active Directory

AD uses its own object classes and attributes, does not allow anonymous search, and is usually reached over LDAPS. For the dashboard:

    LDAP_URI=ldaps://dc1.ad.example.edu
    LDAP_USER_BASE=OU=People,DC=ad,DC=example,DC=edu
    LDAP_GROUP_BASE=OU=Groups,DC=ad,DC=example,DC=edu
    LDAP_BIND_DN=CN=svc-slurmweb,OU=Service Accounts,DC=ad,DC=example,DC=edu
    LDAP_BIND_PASSWORD=...
    LDAP_USER_CLASS=user
    LDAP_USER_NAME_ATTRIBUTE=sAMAccountName
    LDAP_USER_FULLNAME_ATTRIBUTE=displayName
    LDAP_GROUP_OBJECT_CLASSES=group
    LDAP_RESTRICTED_GROUPS=hpc-users
    SLURMWEB_ADMIN_GROUP=hpc-admins

The nodes' `nslcd` configuration expects RFC 2307 attributes (`uid`, `uidNumber`, `memberUid`). AD needs extra `map` lines in `start_nslcd` in `entrypoint.sh`. This AD profile has not been tested against a live domain controller.

### TLS

`ldaps://` and StartTLS check the server certificate. A certificate from a public CA validates against the system CA bundle. For a campus or internal CA, put the CA certificate's PEM text in `LDAP_CACERT_PEM` (gateway only, see above). A double-quoted value can span lines in `.env`:

    LDAP_CACERT_PEM="-----BEGIN CERTIFICATE-----
    MIID...
    -----END CERTIFICATE-----"

### Secrets

The gateway's bind password and CA are passed as Compose configs, not bind mounts, so the repo can still live on a volume the Podman machine does not share. The nodes get the bind password as an environment variable. Both are visible in `podman compose config`. Use a read-only service account limited to searching users and groups.

### Network Access

The containers must reach the directory server:

- With Podman on macOS, traffic leaves through the Podman machine and then the Mac, so VPN routes and DNS on the Mac apply. If the directory is only reachable over a campus VPN, connect the VPN first.
- Firewalls in front of the directory see the Mac's address (or the NAT address of your network) as the client.
- A directory running on the Mac itself is reachable as `host.containers.internal` (Podman) or `host.docker.internal` (Docker).

## Checking the Setup

Check that a node can see a user and their groups:

    podman exec compute1 id alice
    podman exec compute1 getent group physics

List the users and groups the gateway can see, using the same settings it logs in with:

    podman exec slurm-web-gateway /opt/slurm-web-venv/bin/slurm-web ldap-check

Try a dashboard login from the command line:

    curl -s -X POST -H 'Content-Type: application/json' \
      -d '{"user":"alice","password":"demo"}' http://localhost:5011/api/login

A successful login returns a token with the user's `groups`. Failures return HTTP 401 with the reason (`Invalid user or password`, `User alice is not member of restricted groups`). The gateway logs every attempt (`podman logs slurm-web-gateway`). `podman logs directory-sync` shows the last sync.

The smoke test (`make test`) runs its LDAP checks as `alice` with password `demo`. It checks that alice resolves on every node, that she can log in over SSH and run a job, and that she can sign in to the dashboard. Point it at another account with `LDAP_TEST_USER` and `LDAP_TEST_PASSWORD`, or skip these checks with `LDAP_TEST_USER=`.
