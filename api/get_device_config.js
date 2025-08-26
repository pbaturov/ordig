'use strict'
const generate_keypair = require('./generate_keypair')

// get device config from database
const get_device_config = (hostname, key, db, next) => {
  db.get('SELECT * FROM clients WHERE hostname = ? AND key = ?', hostname, key, (err, row) => {
    if(err){
      next(err)
    }else{
      next(null, row)
    }
  })
}

const add_ipv4_cidr = (ip, net_bits, n) => {
  net_bits = parseInt(net_bits)
  const binStr = ip.split('.').map(o => ('00000000' + parseInt(o).toString(2)).slice(-8)).join('')
  const network = binStr.slice(0, net_bits)
  const host = binStr.slice(net_bits - 32)
  const n_host = parseInt(host, 2) + n
  const n_host_str = ('0'.repeat(32 - net_bits) + n_host.toString(2)).slice(net_bits - 32)
  const n_binStr = network + n_host_str
  return n_binStr.match(/.{8}/g).map(n => parseInt(n, 2)).join('.')
}

const get_next_ip = (pool, db, next) => {
  const net = pool.split('/')[0]
  const net_bits = pool.split('/')[1]
  db.get('SELECT ip FROM clients ORDER BY TIMESTAMP DESC LIMIT 1', (err, row) => {
    if(err){
      next(err)
    }else if(row){ // this IP plus 1
      next(null, add_ipv4_cidr(row.ip, net_bits, 1))
    }else{ // second IP in pool, 1 is reserved for server
      next(null, add_ipv4_cidr(net, net_bits, 2))
    }
  })
}

const set_device_config = (hostname, ip, key, keypair, db, next) => {
  const stmt = db.prepare('INSERT INTO clients (hostname, ip, key, keypair) VALUES (?, ?, ?, ?)')
  stmt.run(hostname, ip, key, JSON.stringify(keypair))
  stmt.finalize(() => {
    next(null, true)
  })
}

module.exports = (hostname, key, db, pool, next) => {
  // check if hostname and key exist, return config
  get_device_config(hostname, key, db, (err, config) => {
    if(err){
      next(err)
    }else if(config){
      next(null, config)
    }else{
      // generate config, write to db, send it
      get_next_ip(pool, db, (err, ip) => {
        const keypair = generate_keypair()
        set_device_config(hostname, ip, key, keypair, db, () => {
          get_device_config(hostname, key, db, (err, config) => {
            if(err || !config){
              next(err)
            }else{
              next(null, config)
            }
          })
        })
      })
    }
  })
}