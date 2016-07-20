Camping At The Mailbox
======================

Camping at the Mailbox is a lightweight mail system, intended to be quick,
usable, and work even on limited devices like a Kindle, Nook, mobile browser or
ancient PC.

Features
--------

- Manipulating messages:
	- Read (including attachments)
	- Move to folders
	- Delete
	- Send, including handling large attachments

- Address book
	- AJAX autocompleted text entry for To: &c. fields.
	- LDAP directory read support

Setup
-----

`mailbox.conf` contains values to configure Camping at the Mailbox.

Required settings
-----------------

`imaphost` and `smtphost`, both of which can use the 
token `%{domain}`, which will be replaced by the domain in the
supplied username, or a guess from the HTTP host.

Optional settings
-----------------

`imapport` and `smtpport` can be used to change which 
ports are connected to. Ruby's Net::IMAP module will use SSL on port 993 for 
IMAP.

`imapssl`, if present, will force the use of SSL for IMAP
connections.

`smtpauth`, if present, will authenticate submissions to the SMTP
server with the same credentials used for IMAP

`smtptls`, if present, will force all SMTP connections to begin
with STARTLS (unconditionally at the moment)

`ldaphost` will activate LDAP directory lookups, and takes a
%{domain} token as well.

`ldapport` selects the port to connect to.

`ldapbase` will choose the base DN to search in an LDAP directory,
and will expand `%{domain}` into LDAP DN form 
(`dc=example,dc=org`). 

`ldapmailattr` specifies the attribute to use as the email 
address.

`ldapnameattr` specifies the attribute to use as the user's name.

`ldaprdnattr` specifies the attribute to use to look up a user
by RDN

Make sure that both the name and mail attributes are mandatory in your LDAP
schema.

Other files
-----------

You can make a file `banner`, which will be displayed on the login
screen.

Schema
------

    CREATE TABLE addresses (id integer primary key, name varchar(255), 
        address varchar(255) not null, user_id varchar(255) not null);
    CREATE TABLE sessions ("id" INTEGER PRIMARY KEY NOT NULL NOT NULL, 
        "hashid" varchar(32), "created_at" datetime, "ivars" text);
    CREATE UNIQUE INDEX addresses_uniq on addresses (user_id, address);
